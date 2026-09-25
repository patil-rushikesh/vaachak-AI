"""Durable, bounded local analysis: pending Attempt rows are the work queue.

Run one application process per data directory. A file lock rejects accidental
second workers; interrupted work remains pending and resumes on the next start.
"""
import logging
import threading
from pathlib import Path

from sqlalchemy import select

from .domain_models import Attempt

LOGGER = logging.getLogger(__name__)


class AnalysisQueue:
    def __init__(self, factory, directory, poll_seconds=2.0):
        self.factory = factory
        self.directory = Path(directory)
        self.poll_seconds = poll_seconds
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread = None
        self._lock_file = None

    def start(self):
        if self._thread is not None:
            raise RuntimeError("Analysis worker has already been started")
        import fcntl
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_file = (self.directory / ".analysis-worker.lock").open("a+")
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            lock_file.close()
            raise RuntimeError("Another analysis worker is using this data directory. Run the backend with one process.") from exc
        self._lock_file = lock_file
        self._thread = threading.Thread(target=self._run, name="vaachak-analysis", daemon=True)
        try:
            self._thread.start()
        except Exception:
            self._release_lock()
            self._thread = None
            raise
        return self

    def wake(self):
        self._wake.set()

    def stop(self, timeout=10):
        self._stop.set()
        self._wake.set()
        if self._thread:
            self._thread.join(timeout=timeout)
            if self._thread.is_alive():
                # Retain the lock until the in-flight handler returns, or until
                # process exit releases it. Never start two model workers.
                LOGGER.warning("Analysis is finishing an in-flight job; its pending record survives process exit")
                return False
        return True

    def _release_lock(self):
        if self._lock_file is not None:
            import fcntl
            fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_UN)
            self._lock_file.close()
            self._lock_file = None

    def _next_pending(self):
        with self.factory() as session:
            return session.scalar(select(Attempt.id).where(Attempt.status == "pending", Attempt.reviewed_at.is_(None))
                                  .order_by(Attempt.created_at, Attempt.id).limit(1))

    def _run(self):
        try:
            while not self._stop.is_set():
                # Clearing before the read avoids losing a wakeup that arrives
                # between the empty-queue query and the wait.
                self._wake.clear()
                try:
                    identifier = self._next_pending()
                    if identifier is None:
                        self._wake.wait(self.poll_seconds)
                        continue
                    from .domain_api import _run_analysis
                    _run_analysis(self.factory, self.directory, identifier)
                    # A transient persistence error must not create a tight loop.
                    with self.factory() as session:
                        attempt = session.get(Attempt, identifier)
                        unchanged = attempt is not None and attempt.status == "pending"
                    if unchanged:
                        self._stop.wait(max(self.poll_seconds, 1.0))
                except Exception:
                    LOGGER.exception("Analysis queue temporarily unavailable; saved submissions will be retried")
                    self._stop.wait(max(self.poll_seconds, 1.0))
        finally:
            self._release_lock()
