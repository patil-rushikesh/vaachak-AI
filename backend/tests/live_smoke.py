"""Exercise the API over real HTTP in an isolated, disposable local server.

Optional local models are explicitly selected; this script never calls paid providers.
"""
import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
from uuid import uuid4
import wave

import httpx
import numpy as np


def test_audio():
    """A test tone checks media transport only; it is not human speech evidence."""
    stream = io.BytesIO()
    with wave.open(stream, 'wb') as audio:
        audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        samples = np.sin(np.arange(32000) * 2 * np.pi * 220 / 16000) * 6000
        audio.writeframes(samples.astype('<i2').tobytes())
    return stream.getvalue()


def check_pitch(pitch, *, require_available=False):
    """Validate persisted/HTTP evidence, without claiming pronunciation or emotion accuracy."""
    assert pitch['status'] in {'available', 'insufficient_evidence', 'unavailable'}
    assert pitch['score'] is None and pitch['experimental'] is True
    assert pitch['algorithm_version'] == 'yin-cmndf-v1'
    assert pitch['confidence_kind'] == 'periodicity_not_probability'
    frames = pitch['frames']
    assert len(frames) <= 1000
    times = [frame['time_seconds'] for frame in frames]
    assert all(math.isfinite(stamp) and stamp >= 0 for stamp in times)
    assert all(left < right for left, right in zip(times, times[1:]))
    low, high = pitch['frequency_range_hz']
    for frame in frames:
        assert 0 <= frame['confidence'] <= 1
        assert frame['voiced'] == (frame['f0_hz'] is not None)
        if frame['voiced']:
            assert math.isfinite(frame['f0_hz']) and low <= frame['f0_hz'] <= high
    if require_available:
        assert pitch['status'] == 'available', pitch
        assert pitch['summary']['median_f0_hz'] > 0
        assert pitch['summary']['voiced_seconds'] > 0
        assert any(frame['voiced'] for frame in frames)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio', type=Path, help='Optional known speech fixture; otherwise a test tone is used.')
    parser.add_argument('--speech-model', type=Path, help='Installed local faster-whisper directory; no download.')
    parser.add_argument('--ollama-model', help='Opt in to an already installed local Ollama model.')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    source = args.audio.read_bytes() if args.audio else test_audio()
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix='vaachak-live-check-') as temp:
        directory = Path(temp)
        env = {**os.environ, 'DATABASE_URL': f'sqlite:///{directory / "check.sqlite3"}',
               'VAACHAK_DATA_DIR': temp, 'VAACHAK_TEXT_PROVIDER': 'ollama' if args.ollama_model else '',
               'VAACHAK_TEXT_MODEL': args.ollama_model or '', 'VAACHAK_AUTO_GRADE_MEANING': '0',
               'VAACHAK_WHISPER_MODEL': str(args.speech_model.resolve()) if args.speech_model else ''}
        with (directory / 'server.log').open('w+') as log:
            server = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'vaachak_backend.api:create_app',
                                       '--factory', '--host', '127.0.0.1', '--port', str(port), '--no-access-log'],
                                      cwd=project, env=env, stdout=log, stderr=log)
            try:
                with httpx.Client(base_url=f'http://127.0.0.1:{port}', timeout=40) as client:
                    for _ in range(120):
                        if server.poll() is not None:
                            raise RuntimeError('Isolated API failed to start')
                        try:
                            if client.get('/health').status_code == 200:
                                break
                        except httpx.ConnectError:
                            pass
                        time.sleep(0.2)
                    else:
                        raise RuntimeError('Isolated API startup timed out')

                    def call(method, path, token=None, expected=200, **kwargs):
                        response = client.request(method, path, headers={'Authorization': f'Bearer {token}'} if token else {}, **kwargs)
                        assert response.status_code == expected, (method, path, response.status_code, response.text)
                        return response.json() if response.content else None

                    password = secrets.token_urlsafe(18)
                    teacher_profile = {'country': 'Fixture country', 'state_region': 'Fixture region',
                                       'city': 'Reference city', 'first_language': 'English', 'target_accent': 'Teacher-selected English'}
                    teacher = call('POST', '/auth/register', expected=201,
                                   json={'email': 'http-check@example.test', 'password': password,
                                         'learning_profile': teacher_profile})['access_token']
                    saved_profile = call('GET', '/teacher/profile', teacher)['learning_profile']
                    assert all(saved_profile[key] == value for key, value in teacher_profile.items())
                    assert saved_profile['provenance'] == 'self_reported'
                    room = call('POST', '/teacher/classrooms', teacher, 201,
                                json={'school_name': 'HTTP verification fixture', 'name': 'Class 6', 'postal_code': '411001'})
                    student = call('POST', f'/teacher/classrooms/{room["id"]}/students', teacher, 201,
                                   json={'display_name': 'Synthetic test student', 'login_name': 'http-check', 'password': password,
                                         'learning_profile': {'country': 'Fixture country', 'city': 'Learner city', 'first_language': 'English'}})
                    assert student['learning_profile']['provenance'] == 'teacher_entered'
                    definitions = [
                        {'title': 'Read a sentence', 'kind': 'read_aloud',
                         'expected_text': 'Okay, this is my house. I love reading books with my friends.',
                         'payload': {'expression': 'Welcoming'}},
                        {'title': 'A synonym', 'kind': 'choice', 'expected_text': 'Choose a synonym for happy.',
                         'payload': {'options': [{'id': 'a', 'text': 'Joyful'}, {'id': 'b', 'text': 'Sad'}], 'correct_option_id': 'a', 'skill': 'synonym'}},
                        {'title': 'Opposites', 'kind': 'matching', 'expected_text': 'Match opposites.',
                         'payload': {'pairs': [{'id': 'a', 'left': 'Hot', 'right': 'Cold'}, {'id': 'b', 'left': 'Early', 'right': 'Late'}], 'skill': 'antonym'}},
                        {'title': 'Explain the meaning', 'kind': 'meaning', 'expected_text': 'Lend me a hand with these books.',
                         'payload': {'accepted_answers': ['Please help me carry these books.'], 'rubric': 'Ask for help carrying books.'}},
                    ]
                    problems = [call('POST', '/teacher/problems', teacher, 201, json=body) for body in definitions]
                    recording = call('POST', f'/problems/{problems[0]["id"]}/recordings', teacher, 201,
                                     files={'file': ('fixture.wav', source, 'audio/wav')})
                    assert recording['original_sha256'] == hashlib.sha256(source).hexdigest()
                    assert (directory / 'recordings' / recording['id'] / 'original').read_bytes() == source
                    normalized_reference = directory / 'recordings' / recording['id'] / 'reference.wav'
                    assert recording['normalized_sha256'] == hashlib.sha256(normalized_reference.read_bytes()).hexdigest()
                    reference = recording['measurements']
                    assert reference['learning_context']['learning_profile']['city'] == 'Reference city'
                    assert reference['learning_context']['recorded_at']
                    call('PATCH', '/teacher/profile', teacher, json={'learning_profile': {'city': 'Updated reference city'}})
                    assert (reference['sample_rate'], reference['channels'], reference['sample_format']) == (16000, 1, 'PCM_S16LE')
                    assert reference['preservation']['original'] == 'byte_for_byte'
                    assert reference['preservation']['processing'] == 'resample_and_downmix_only'
                    assert reference['preservation']['pause_trimming'] is False
                    assert reference['preservation']['pitch_analysis'] == 'yin-cmndf-v1'
                    check_pitch(reference['pitch'], require_available=bool(args.audio))
                    if source[:4] == b'RIFF' and reference['source_media'].get('status') != 'unavailable':
                        with wave.open(io.BytesIO(source), 'rb') as original_wave:
                            assert int(reference['source_media']['sample_rate']) == original_wave.getframerate()
                            assert reference['source_media']['channels'] == original_wave.getnchannels()
                    stored_problem = call('GET', f'/teacher/problems/{problems[0]["id"]}', teacher)
                    assert stored_problem['recordings'][0]['measurements'] == reference
                    assignment_body = {'request_id': str(uuid4()), 'title': 'HTTP integration verification', 'classroom_id': room['id'],
                                       'problems': [{'problem_id': p['id'], **({'recording_id': recording['id']} if i == 0 else {})} for i, p in enumerate(problems)]}
                    assignment = call('POST', '/teacher/assignments', teacher, 201, json=assignment_body)
                    assert call('POST', '/teacher/assignments', teacher, 201, json=assignment_body)['id'] == assignment['id']
                    learner = call('POST', '/auth/login', json={'identifier': 'http-check', 'password': password, 'role': 'student'})['access_token']
                    edited_profile = call('PATCH', '/student/profile', learner,
                                          json={'learning_profile': {'city': '', 'target_accent': 'Clear classroom English'}})['learning_profile']
                    assert edited_profile['country'] == 'Fixture country' and edited_profile['city'] == ''
                    assert edited_profile['provenance'] == 'self_reported'
                    assert call('GET', f'/teacher/students/{student["id"]}', teacher)['learning_profile']['target_accent'] == 'Clear classroom English'
                    call('GET', '/teacher/profile', learner, 403)
                    detail = call('GET', f'/student/assignments/{assignment["id"]}', learner)
                    assert 'correct_option_id' not in json.dumps(detail)
                    assert 'accepted_answers' not in json.dumps(detail)
                    items = {item['kind']: item for item in detail['problems']}

                    def submit(kind, answer):
                        path = f'/student/assignments/{assignment["id"]}/problems/{items[kind]["id"]}/attempts'
                        body = {'request_id': str(uuid4()), 'answer': answer}
                        result = call('POST', path, learner, 201, json=body)
                        assert call('POST', path, learner, 201, json=body)['id'] == result['id']
                        return result

                    choice = submit('choice', 'a')
                    assert choice['score'] == 1
                    assert choice['display_feedback']['headline']
                    matching = items['matching']['payload']
                    right = {card['text']: card['id'] for card in matching['right']}
                    answer = {card['id']: right[{'Hot': 'Cold', 'Early': 'Late'}[card['text']]] for card in matching['left']}
                    assert submit('matching', answer)['score'] == 1
                    meaning = submit('meaning', 'They want somebody to assist them with carrying books.')
                    path = f'/student/assignments/{assignment["id"]}/problems/{items["read_aloud"]["id"]}/recordings'
                    request_id = str(uuid4())
                    reading = call('POST', path, learner, 201, data={'request_id': request_id}, files={'file': ('fixture.wav', source, 'audio/wav')})
                    assert call('POST', path, learner, 201, data={'request_id': request_id}, files={'file': ('fixture.wav', source, 'audio/wav')})['id'] == reading['id']
                    assert (directory / 'attempts' / reading['id'] / 'original').read_bytes() == source

                    def poll(attempt):
                        deadline = time.monotonic() + 100
                        while time.monotonic() < deadline:
                            result = call('GET', f'/student/attempts/{attempt["id"]}', learner)
                            if result['status'] != 'pending':
                                return result
                            time.sleep(0.2)
                        raise AssertionError('Analysis stayed pending')

                    meaning, reading = poll(meaning), poll(reading)
                    assert meaning['status'] == 'needs_review' and meaning['score'] is None
                    assert reading['status'] in {'completed', 'needs_review'}
                    assert reading['measurements']['learning_context']['learning_profile']['target_accent'] == 'Clear classroom English'
                    assert reading['measurements']['learning_context']['learning_profile']['city'] == ''
                    feedback = reading['display_feedback']
                    assert feedback['headline'] and feedback['summary']
                    dimensions = {dimension['key']: dimension for dimension in feedback['dimensions']}
                    for key in ('pace', 'pauses', 'pitch', 'pronunciation'):
                        assert dimensions[key]['score'] is None
                    assert 'suggested_score' not in json.dumps(meaning['display_feedback'])
                    check_pitch(reading['result']['pitch'], require_available=bool(args.audio))
                    assert reading['result']['pronunciation'] == {'status': 'not_assessed', 'score': None}
                    assert reading['result']['emotion'] == {'status': 'not_assessed', 'score': None}
                    if args.speech_model and args.audio:
                        assert reading['status'] == 'completed', reading['result']
                        assert reading['result']['reference_comparison']['status'] == 'available'
                        comparison = reading['result']['pitch']['reference_comparison']
                        assert comparison['status'] == 'available', comparison
                        assert comparison['method'] == 'word_aligned_speaker_centered_contour'
                        assert len(comparison['points']) >= 3
                        # This smoke deliberately submits the identical fixture as both voices.
                        assert comparison['median_absolute_difference_semitones'] < 0.25
                        assert abs(reading['score'] - reading['result']['word_accuracy']) < 0.0001
                    teacher_detail = call('GET', f'/teacher/students/{student["id"]}', teacher)
                    teacher_reading = next(attempt for attempt in teacher_detail['attempts'] if attempt['id'] == reading['id'])
                    assert teacher_reading['reference_audio_url'] == recording['playback_url']
                    stored_reference = call('GET', f'/teacher/problems/{problems[0]["id"]}', teacher)['recordings'][0]
                    assert stored_reference['measurements']['learning_context']['learning_profile']['city'] == 'Reference city'
                    automatic_reading = {'status': reading['status'], 'score': reading['score'], 'result': reading['result']}
                    automatic_meaning = {'status': meaning['status'], 'score': meaning['score'], 'result': meaning['result']}
                    for attempt in [meaning, reading]:
                        reviewed = call('PATCH', f'/teacher/attempts/{attempt["id"]}/review', teacher,
                                        json={'score': 0.75, 'feedback': 'Synthetic API verification review.'})
                        assert reviewed['score'] == 0.75
                        assert call('GET', f'/student/attempts/{attempt["id"]}', learner)['score'] == 0.75
                    overview = call('GET', '/student/overview', learner)
                    assert overview['counts']['attempts'] == 4
                    assert overview['counts']['completed_assignments'] == 1
                    assert overview['counts']['solved_problems'] == 4
                    assert overview['progress']['current_practice_status'] == {
                        'graded': 4, 'pending': 0, 'needs_review': 0, 'not_started': 0, 'total': 4}
                    # A learner enrolled later does not inherit the frozen recipient list.
                    call('POST', f'/teacher/classrooms/{room["id"]}/students', teacher, 201,
                         json={'display_name': 'Unassigned test student', 'login_name': 'unassigned-check', 'password': password})
                    outsider = call('POST', '/auth/login', json={'identifier': 'unassigned-check', 'password': password, 'role': 'student'})['access_token']
                    call('GET', f'/student/assignments/{assignment["id"]}', outsider, 404)
                    call('GET', f'/student/reference-recordings/{recording["id"]}/audio', outsider, 404)
                    call('POST', '/auth/logout', learner, 204)
                    call('GET', '/student/overview', learner, 401)
                    report = {'status': 'passed', 'transport': 'real HTTP / isolated SQLite', 'attempts': 4,
                              'coverage': ['teacher/student auth', 'classroom provisioning', 'four exercise types', 'immutable assignments',
                                           'retry idempotency', 'private media', 'original waveform preservation', 'reference media metadata', 'experimental pitch contours',
                                           'word-aligned relative pitch comparison' if args.speech_model and args.audio else 'pitch evidence without grading',
                                           'async polling', 'teacher reviews', 'progress', 'regional profiles and capture snapshots',
                                           'plain-language feedback without invented voice grades', 'completion chart counts', 'logout'],
                              'speech_fixture': 'provided test audio' if args.audio else 'test tone; no speech validity claim',
                              'local_speech_enabled': bool(args.speech_model), 'local_meaning_enabled': bool(args.ollama_model),
                              'meaning_outcome': 'ai_suggestion_for_teacher' if meaning['result'].get('method') == 'ai_semantic_review' else 'teacher_review_fallback',
                              'reference_metadata': {'normalized_sha256': recording['normalized_sha256'], 'source_media': reference['source_media'],
                                                     'preservation': reference['preservation'], 'pitch_summary': reference['pitch']['summary'],
                                                     'pitch_algorithm': reference['pitch']['algorithm_version']},
                              'automatic_reading': automatic_reading, 'automatic_meaning': automatic_meaning}
                    if args.report:
                        args.report.parent.mkdir(parents=True, exist_ok=True)
                        args.report.write_text(json.dumps(report, indent=2) + '\n')
                    print(json.dumps({key: value for key, value in report.items() if not key.startswith('automatic_')}, indent=2))
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == '__main__':
    main()
