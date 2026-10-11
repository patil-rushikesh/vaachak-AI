"""Cloud storage access, restart survival, ranges, and sanitized failures."""
from contextlib import contextmanager
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path

import pytest
from botocore.response import StreamingBody
from botocore.exceptions import ClientError
import audio_store
import db
from .test_api import WAV


@pytest.fixture
def bucket(monkeypatch):
    objects = {}
    class Client:
        def close(self): pass
        def put_object(self, **kw):
            objects[kw['Key']] = kw['Body']
        def get_object(self, **kw):
            if kw['Key'] not in objects:
                raise ClientError({'Error': {'Code': 'NoSuchKey'}}, 'GetObject')
            data = objects[kw['Key']]
            return {'Body': StreamingBody(BytesIO(data), len(data))}
        def delete_object(self, **kw):
            objects.pop(kw['Key'], None)
    monkeypatch.setenv('VAACHAK_AUDIO_STORAGE', 's3')
    monkeypatch.setenv('VAACHAK_AUDIO_BUCKET', 'test-private')
    monkeypatch.setenv('AWS_ENDPOINT_URL_S3', 'https://storage.example.test')
    monkeypatch.setenv('AWS_ACCESS_KEY_ID', 'test')
    monkeypatch.setenv('AWS_SECRET_ACCESS_KEY', 'test')
    monkeypatch.setattr(audio_store, '_client', Client)
    return objects


def test_private_recording_survives_empty_local_disk_and_supports_ranges(client, world, bucket):
    r = client.post('/api/recordings', headers=world['t'], data={'title':'Cloud audio', 'duration_ms':1000}, files={'file':('voice.wav',WAV,'audio/wav')})
    assert r.status_code == 200, r.text
    path=f"/api/recordings/{r.json()['id']}/audio"
    assert len(bucket)==1
    assert not (db.data_dir()/'audio'/next(iter(bucket))).exists()
    assert client.get(path, headers=world['b']).status_code == 404
    assert client.get(path).status_code == 401
    assert client.get(path, headers=world['t']).content == WAV
    ranged=client.get(path, headers={**world['t'], 'Range':'bytes=0-15'})
    assert ranged.status_code==206
    assert ranged.content==WAV[:16]
    assert client.delete(path.removesuffix('/audio'),headers=world['t']).status_code==200
    assert not bucket


def test_temp_downloads_removed_after_asr_and_failed_reads(bucket):
    audio_store.put('voice.wav',WAV,'audio/wav')
    with audio_store.local_path('voice.wav') as path:
        assert path.read_bytes()==WAV
    assert not path.exists()
    with pytest.raises(Exception) as exc:
        with audio_store.local_path('missing.wav'): pass
    assert exc.value.status_code==404
    audio_store.copy('voice.wav','copy.wav','audio/wav')
    assert bucket['copy.wav']==WAV


def test_cloud_failure_has_safe_error_envelope(client, world, bucket, monkeypatch):
    def fail(*a, **k):
        raise audio_store.StorageUnavailable('provider details must not escape')
    monkeypatch.setattr(audio_store,'put',fail)
    r=client.post('/api/recordings',headers=world['t'],data={'title':'Test','duration_ms':1000},files={'file':('a.wav',WAV,'audio/wav')})
    assert r.status_code==503
    assert r.json()['error']['request_id']
    assert 'provider details' not in r.text
    assert client.get('/api/recordings',headers=world['t']).json()==[]


def test_remote_delete_failure_preserves_record_for_retry(client, world, bucket, monkeypatch):
    r=client.post('/api/recordings',headers=world['t'],data={'title':'Test','duration_ms':1000},files={'file':('a.wav',WAV,'audio/wav')}).json()
    def fail(*a): raise audio_store.StorageUnavailable('failed')
    monkeypatch.setattr(audio_store,'delete',fail)
    assert client.delete(f"/api/recordings/{r['id']}",headers=world['t']).status_code==503
    assert len(client.get('/api/recordings',headers=world['t']).json())==1


def test_production_postgres_rejects_ephemeral_audio(monkeypatch):
    monkeypatch.setenv('DATABASE_URL','postgresql://unused')
    monkeypatch.setenv('VAACHAK_ENV','production')
    monkeypatch.setenv('VAACHAK_AUDIO_STORAGE','local')
    with pytest.raises(ValueError, match='durable'):
        audio_store.validate_config()


def test_production_database_requires_tls(monkeypatch):
    import postgres
    monkeypatch.setenv('VAACHAK_ENV', 'production')
    with pytest.raises(ValueError, match='TLS'):
        postgres.validate_url('postgresql://user:password@db.example/vaachak')
    postgres.validate_url('postgresql://user:password@db.example/vaachak?sslmode=require')


def test_inline_worker_drains_new_durable_job(client, world, monkeypatch):
    import inline_worker
    import time
    from uuid import uuid4
    monkeypatch.setenv('VAACHAK_RUN_WORKER', 'inline')
    inline_worker.start()
    try:
        r = client.post('/api/ai/jobs', headers=world['t'], json={'client_uuid':str(uuid4()), 'topic':'Greeting', 'count':1, 'level':'A1'})
        assert r.status_code == 200, r.text
        job_id = r.json()['id']
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            job = client.get(f'/api/ai/jobs/{job_id}', headers=world['t']).json()
            if job['status'] in ('failed','completed'):
                break
            time.sleep(0.02)
        assert job['status'] == 'failed'  # Provider intentionally disabled in tests.
        assert job['tries'] == 1
        assert job['error_code'] == 'generation_unavailable'
    finally:
        inline_worker.stop()
