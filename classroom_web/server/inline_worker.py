"""Request-woken job runner for a sleeping, single-instance free web service.

No idle database polling: enqueue wakes the thread. Startup drains durable jobs;
unexpired leases get one scheduled wake-up so crashes recover without a user.
"""
import logging
import threading
from datetime import datetime, timezone
import db

log = logging.getLogger('vaachak.jobs')
_wake = threading.Event()
_stop = threading.Event()
_thread = None


def wake():
    _wake.set()


def _run():
    from generation_jobs import work_once
    while not _stop.is_set():
        _wake.wait()
        _wake.clear()
        if _stop.is_set():
            break
        try:
            while not _stop.is_set() and work_once():
                pass
            with db.connect() as conn:
                lease = conn.execute("SELECT min(lease_until) FROM generation_jobs WHERE status='running'").fetchone()[0]
            if lease and not _stop.is_set():
                delay = max(1, (datetime.fromisoformat(lease) - datetime.now(timezone.utc)).total_seconds()+1)
                _wake.wait(timeout=min(delay, 601))
                _wake.set()
        except Exception as exc:
            # Type only: provider/connection exceptions may contain credentials.
            log.warning('Job runner retry: %s', type(exc).__name__)
            if not _stop.wait(10):
                _wake.set()


def start():
    global _thread
    if _thread and _thread.is_alive():
        return
    _stop.clear()
    _wake.set()
    _thread = threading.Thread(target=_run, name='vaachak-drafts', daemon=True)
    _thread.start()


def stop():
    _stop.set()
    _wake.set()
    if _thread:
        _thread.join(timeout=2)
