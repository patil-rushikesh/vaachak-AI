"""Private audio storage: local files for development, S3-compatible Neon in cloud.

All access still passes the existing API ownership checks. Temporary downloads
exist only for ffmpeg/ASR or ranged playback and are deleted after use.
"""
from contextlib import contextmanager
import os
import logging
from pathlib import Path
import re
import tempfile

from fastapi import HTTPException
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask
import db


class StorageUnavailable(Exception):
    pass


def remote():
    return os.getenv('VAACHAK_AUDIO_STORAGE', 'local') == 's3'


def validate_config():
    mode = os.getenv('VAACHAK_AUDIO_STORAGE', 'local')
    if mode not in ('local', 's3'):
        raise ValueError('VAACHAK_AUDIO_STORAGE must be local or s3')
    if remote():
        required = ('AWS_ENDPOINT_URL_S3', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'VAACHAK_AUDIO_BUCKET')
        if any(not os.getenv(k) for k in required):
            raise ValueError('S3 audio storage configuration is incomplete')
        from urllib.parse import urlparse
        url = urlparse(os.environ['AWS_ENDPOINT_URL_S3'])
        if os.getenv('VAACHAK_ENV') == 'production' and (url.scheme != 'https' or url.username or url.password):
            raise ValueError('Production object storage requires HTTPS without URL credentials')
    elif db.is_postgres() and os.getenv('VAACHAK_ENV') == 'production':
        raise ValueError('Cloud Postgres requires durable S3 audio storage in production')


def _key(name):
    if not re.fullmatch(r'[a-zA-Z0-9_-]+\.[a-z0-9]+', name):
        raise ValueError('Invalid audio object name')
    return name


def _client():
    import boto3
    from botocore.config import Config
    return boto3.client('s3', endpoint_url=os.environ['AWS_ENDPOINT_URL_S3'],
        aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
        aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
        region_name=os.getenv('AWS_REGION', 'us-east-2'),
        config=Config(signature_version='s3v4', connect_timeout=10, read_timeout=30,
                      retries={'max_attempts': 2, 'mode': 'standard'},
                      s3={'addressing_style': 'path'},
                      request_checksum_calculation='when_required', response_checksum_validation='when_required'))


@contextmanager
def _service():
    from botocore.exceptions import BotoCoreError, ClientError
    client = _client()
    try:
        yield client, os.environ['VAACHAK_AUDIO_BUCKET']
    except ClientError as exc:
        if str(exc.response.get('Error', {}).get('Code')) in ('NoSuchKey', '404'):
            raise HTTPException(404, 'Audio file is no longer available.') from None
        raise StorageUnavailable('Audio storage is temporarily unavailable.') from None
    except BotoCoreError:
        raise StorageUnavailable('Audio storage is temporarily unavailable.') from None
    finally:
        client.close()


def put(name, data, mime):
    name = _key(name)
    if remote():
        with _service() as (client, bucket):
            client.put_object(Bucket=bucket, Key=name, Body=data, ContentType=mime)
    else:
        (db.data_dir() / 'audio' / name).write_bytes(data)


def delete(name):
    name = _key(name)
    if remote():
        with _service() as (client, bucket):
            client.delete_object(Bucket=bucket, Key=name)
    else:
        (db.data_dir() / 'audio' / name).unlink(missing_ok=True)


def _download(name):
    name = _key(name)
    fd, filename = tempfile.mkstemp(prefix='vaachak-audio-', suffix=Path(name).suffix)
    os.close(fd)
    path = Path(filename)
    try:
        with _service() as (client, bucket):
            obj = client.get_object(Bucket=bucket, Key=name)
            body = obj['Body']
            try:
                # Match maximum recording upload; bound memory and disk consumption.
                size = 0
                with path.open('wb') as out:
                    for chunk in body.iter_chunks(65536):
                        size += len(chunk)
                        if size > 20 * 1024 * 1024:
                            raise StorageUnavailable('Stored audio exceeds the supported limit.')
                        out.write(chunk)
            finally:
                body.close()
        return path
    except BaseException:
        path.unlink(missing_ok=True)
        raise


@contextmanager
def local_path(name):
    path = _download(name) if remote() else db.data_dir() / 'audio' / _key(name)
    try:
        if not path.is_file():
            raise HTTPException(404, 'Audio file is no longer available.')
        yield path
    finally:
        if remote():
            path.unlink(missing_ok=True)


def copy(source, destination, mime):
    with local_path(source) as path:
        put(destination, path.read_bytes(), mime)


def response(name, mime):
    if remote():
        path = _download(name)
        return FileResponse(path, media_type=mime, background=BackgroundTask(path.unlink, missing_ok=True))
    path = db.data_dir() / 'audio' / _key(name)
    if not path.is_file():
        raise HTTPException(404, 'Audio file is no longer available.')
    return FileResponse(path, media_type=mime)


def objects():
    """Name + UTC modification timestamp, for conservative orphan retention."""
    if remote():
        with _service() as (client, bucket):
            for page in client.get_paginator('list_objects_v2').paginate(Bucket=bucket):
                for obj in page.get('Contents', []):
                    yield obj['Key'], obj['LastModified'].timestamp()
    else:
        for path in (db.data_dir() / 'audio').iterdir():
            if path.is_file():
                yield path.name, path.stat().st_mtime


def discard(name):
    """Failure cleanup must not hide the original error or strand its job status.

    Any object left by a provider outage is removed by orphan retention later.
    """
    try:
        delete(name)
    except Exception as exc:
        logging.getLogger('vaachak.storage').warning('Audio cleanup deferred: %s', type(exc).__name__)
