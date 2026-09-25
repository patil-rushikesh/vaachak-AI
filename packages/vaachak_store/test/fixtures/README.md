# Legacy encryption fixture

`sqlite3mc-v4.db.b64` is a base64-encoded encrypted database generated before switching the workspace hook to SQLCipher Community. It uses sqlite3 3.6.0's SQLite3MultipleCiphers binary with `cipher='sqlcipher'`, `legacy=4` and the 64-character ASCII passphrase consisting of the digit `1` repeated 64 times.

It contains schema version 1 and one synthetic `SessionStarted` event for learner `migration-fixture`, device `legacy-device`, payload `{"fixture":true}`. It contains no real learner data or production secret. The store test decodes it into a temporary directory and proves SQLCipher 4 can read and append without resetting or replacing the existing data.
