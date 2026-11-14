"""Key-value storage for JSON documents.

Three implementations behind one small interface:
- MemoryStore: tests.
- DirStore: a local folder, for development.
- S3Store: any S3-compatible object store (production uses RustFS).

Keys are plain paths such as `clinics/{clinic_id}/patients/{patient_id}/days/2026-11-13.json`.
"""

from __future__ import annotations

import hashlib
import hmac
import http.client
import threading
from datetime import datetime, timezone
from urllib.parse import quote, urlsplit
import json
import os
import re
import threading
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

from .config import Settings

_KEY_RE = re.compile(r"^[A-Za-z0-9_\-./]+$")


def check_key(key: str) -> str:
    if not key or not _KEY_RE.match(key) or ".." in key or key.startswith("/"):
        raise ValueError("invalid store key")
    return key


class Store(ABC):
    @abstractmethod
    def get(self, key: str) -> dict | None: ...

    @abstractmethod
    def put(self, key: str, doc: dict) -> None: ...

    @abstractmethod
    def delete(self, key: str) -> None: ...

    @abstractmethod
    def list(self, prefix: str) -> list[str]:
        """Return all keys that start with prefix, sorted."""

    def get_many(self, keys: list[str]) -> list[dict | None]:
        """One result per key, in the same order."""
        return [self.get(k) for k in keys]

    def list_docs(self, prefix: str) -> list[dict]:
        return [d for d in self.get_many(self.list(prefix)) if d is not None]

    def delete_prefix(self, prefix: str) -> int:
        keys = self.list(prefix)
        for k in keys:
            self.delete(k)
        return len(keys)


class MemoryStore(Store):
    def __init__(self) -> None:
        self._data: dict[str, str] = {}
        self._lock = threading.Lock()

    def get(self, key: str) -> dict | None:
        raw = self._data.get(check_key(key))
        return json.loads(raw) if raw is not None else None

    def put(self, key: str, doc: dict) -> None:
        raw = json.dumps(doc, sort_keys=True)
        with self._lock:
            self._data[check_key(key)] = raw

    def delete(self, key: str) -> None:
        with self._lock:
            self._data.pop(check_key(key), None)

    def list(self, prefix: str) -> list[str]:
        return sorted(k for k in list(self._data) if k.startswith(prefix))


class DirStore(Store):
    def __init__(self, root: str) -> None:
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        p = (self.root / check_key(key)).resolve()
        if self.root not in p.parents:
            raise ValueError("invalid store key")
        return p

    def get(self, key: str) -> dict | None:
        p = self._path(key)
        try:
            return json.loads(p.read_text("utf-8"))
        except FileNotFoundError:
            return None

    def put(self, key: str, doc: dict) -> None:
        p = self._path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + f".tmp{os.getpid()}.{threading.get_ident()}")
        tmp.write_text(json.dumps(doc, sort_keys=True, indent=1), "utf-8")
        os.replace(tmp, p)

    def delete(self, key: str) -> None:
        try:
            self._path(key).unlink()
        except FileNotFoundError:
            pass

    def list(self, prefix: str) -> list[str]:
        # Walk only the deepest folder the prefix names.
        base = prefix.rsplit("/", 1)[0] if "/" in prefix else ""
        start = self.root / base if base else self.root
        if not start.exists():
            return []
        out = []
        for dirpath, _dirs, files in os.walk(start):
            for f in files:
                if ".tmp" in f:
                    continue
                key = os.path.relpath(os.path.join(dirpath, f), self.root).replace(os.sep, "/")
                if key.startswith(prefix):
                    out.append(key)
        return sorted(out)


class _SignedReader:
    """GET one object with an AWS signature (version 4) over one kept-open
    connection. Plain http endpoints only (the store sits on the same host).
    Returns (True, doc), (False, None) for a missing key, or (None, None) when it
    cannot say and the caller should use the general client."""

    _EMPTY = hashlib.sha256(b"").hexdigest()

    def __init__(self, endpoint_url: str, bucket: str, access_key: str, secret_key: str,
                 region: str) -> None:
        u = urlsplit(endpoint_url or "")
        self.ok = u.scheme == "http" and bool(u.netloc and access_key and secret_key)
        self.host, self.bucket, self.access, self.secret = u.netloc, bucket, access_key, secret_key
        self.region = region or "us-east-1"
        self._conn: http.client.HTTPConnection | None = None
        self._key: tuple[str, bytes] | None = None
        self._lock = threading.Lock()

    def _signing_key(self, day: str) -> bytes:
        if self._key is None or self._key[0] != day:
            k = ("AWS4" + self.secret).encode()
            for part in (day, self.region, "s3", "aws4_request"):
                k = hmac.new(k, part.encode(), hashlib.sha256).digest()
            self._key = (day, k)
        return self._key[1]

    def _headers(self, path: str) -> dict:
        amz = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        scope = f"{amz[:8]}/{self.region}/s3/aws4_request"
        canon = (f"GET\n{path}\n\nhost:{self.host}\nx-amz-content-sha256:{self._EMPTY}\n"
                 f"x-amz-date:{amz}\n\nhost;x-amz-content-sha256;x-amz-date\n{self._EMPTY}")
        to_sign = (f"AWS4-HMAC-SHA256\n{amz}\n{scope}\n"
                   f"{hashlib.sha256(canon.encode()).hexdigest()}")
        sig = hmac.new(self._signing_key(amz[:8]), to_sign.encode(), hashlib.sha256).hexdigest()
        return {"x-amz-date": amz, "x-amz-content-sha256": self._EMPTY,
                "Authorization": f"AWS4-HMAC-SHA256 Credential={self.access}/{scope}, "
                                 f"SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                                 f"Signature={sig}"}

    def get(self, key: str) -> tuple[bool | None, dict | None]:
        if not self.ok:
            return None, None
        path = "/" + self.bucket + "/" + quote(key, safe="/-_.~")
        with self._lock:
            for attempt in (1, 2):  # a kept-open connection may have been closed by the server
                try:
                    if self._conn is None:
                        self._conn = http.client.HTTPConnection(self.host, timeout=10)
                    self._conn.request("GET", path, headers=self._headers(path))
                    resp = self._conn.getresponse()
                    body = resp.read()
                    break
                except Exception:  # noqa: BLE001
                    try:
                        self._conn.close()
                    except Exception:  # noqa: BLE001
                        pass
                    self._conn = None
                    if attempt == 2:
                        return None, None
        if resp.status == 200:
            return True, json.loads(body)
        if resp.status == 404:
            return False, None
        return None, None


class S3Store(Store):
    """S3 API via boto3. Path-style addressing, which RustFS expects."""

    def __init__(self, endpoint_url: str, bucket: str, access_key: str, secret_key: str,
                 region: str = "us-east-1", client: Any = None) -> None:
        self.bucket = bucket
        if client is None:
            import boto3
            from botocore.config import Config

            client = boto3.client(
                "s3",
                endpoint_url=endpoint_url or None,
                aws_access_key_id=access_key or None,
                aws_secret_access_key=secret_key or None,
                region_name=region,
                config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 3},
                              connect_timeout=5, read_timeout=10),
            )
            self._reader = _SignedReader(endpoint_url, bucket, access_key, secret_key, region)
        self.client = client

    _reader = None  # only when this class made its own client (not in tests)

    def get(self, key: str) -> dict | None:
        check_key(key)
        if self._reader is not None:
            # Reading is most of what the engine does, and the general client spends
            # about 3 ms of CPU per object. A plain signed GET takes a third of that.
            try:
                found, doc = self._reader.get(key)
                if found is not None:
                    return doc if found else None
            except Exception:  # noqa: BLE001 - any doubt: ask the general client
                pass
        try:
            obj = self.client.get_object(Bucket=self.bucket, Key=check_key(key))
        except self.client.exceptions.NoSuchKey:
            return None
        except Exception as exc:  # some S3 servers answer 404 without NoSuchKey
            code = getattr(exc, "response", {}).get("Error", {}).get("Code")
            if code in ("404", "NoSuchKey", "NotFound"):
                return None
            raise
        return json.loads(obj["Body"].read())

    def put(self, key: str, doc: dict) -> None:
        self.client.put_object(Bucket=self.bucket, Key=check_key(key),
                               Body=json.dumps(doc, sort_keys=True).encode("utf-8"),
                               ContentType="application/json")

    def delete(self, key: str) -> None:
        self.client.delete_object(Bucket=self.bucket, Key=check_key(key))

    def list(self, prefix: str) -> list[str]:
        out: list[str] = []
        token = None
        while True:
            kw = {"Bucket": self.bucket, "Prefix": prefix}
            if token:
                kw["ContinuationToken"] = token
            resp = self.client.list_objects_v2(**kw)
            out.extend(o["Key"] for o in resp.get("Contents", []))
            if not resp.get("IsTruncated"):
                break
            token = resp.get("NextContinuationToken")
        return sorted(out)


class PackedStore(Store):
    """Keeps a patient's small records together, in front of a store that costs a
    round trip per object. Callers still read and write one record per key; this
    class files them into packs:

    - days, activities, rounds, suggestions, feedback, notes, attention, ratings,
      rejected: one object per folder (`<folder>.pack.json`)
    - audit, trace: one object per folder and day (`<folder>/<yyyymmdd>.pack.json`),
      because they only grow

    Nothing is held between calls: every read fetches the pack again, so two
    processes on the same store see each other's writes. A pack, once it exists,
    holds everything for its folder (or day). Records written before packs existed
    are taken into the pack the first time it is touched.
    """

    WHOLE = ("days", "activities", "rounds", "suggestions", "feedback", "notes", "attention",
             "ratings", "rejected")
    DAILY = ("audit", "trace")
    _KEY = re.compile(r"^(clinics/[^/]+/patients/[^/]+/(%s))/([^/]+\.json)$"
                      % "|".join(WHOLE + DAILY))
    _FOLDER = re.compile(r"^(clinics/[^/]+/patients/[^/]+/(%s))/([^/]*)$"
                         % "|".join(WHOLE + DAILY))
    _SUFFIX = ".pack.json"

    def __init__(self, inner: Store) -> None:
        self.inner = inner
        self._lock = threading.RLock()

    # ---- where a record lives ------------------------------------------------------
    def _route(self, key: str) -> tuple[str, str, str] | None:
        """(pack key, prefix of the single objects this pack replaces, record name)."""
        m = self._KEY.match(key)
        if not m or key.endswith(self._SUFFIX):
            return None
        folder, kind, name = m.group(1), m.group(2), m.group(3)
        if kind in self.WHOLE:
            return folder + self._SUFFIX, folder + "/", name
        day = name[:8] if name[:8].isdigit() else "other"
        return f"{folder}/{day}{self._SUFFIX}", f"{folder}/{day}" if day != "other" else "", name

    def _load(self, pack_key: str, singles_prefix: str, seen: dict | None = None) -> dict:
        """The pack's records by name. Creates the pack from single objects on first touch."""
        if seen is not None and pack_key in seen:
            return seen[pack_key]
        doc = self.inner.get(pack_key)
        if doc is not None:
            docs = doc.get("docs", {})
        else:
            docs = {}
            old = [k for k in self.inner.list(singles_prefix)
                   if not k.endswith(self._SUFFIX)] if singles_prefix else []
            if singles_prefix.endswith("/"):  # a whole folder: direct children only
                old = [k for k in old if "/" not in k[len(singles_prefix):]]
            for k, d in zip(old, self.inner.get_many(old)):
                if d is not None:
                    docs[k.rsplit("/", 1)[1]] = d
            self.inner.put(pack_key, {"pack": 1, "docs": docs})
            for k in old:
                self.inner.delete(k)
        if seen is not None:
            seen[pack_key] = docs
        return docs

    # ---- the Store interface ---------------------------------------------------------
    def get(self, key: str) -> dict | None:
        r = self._route(key)
        if r is None:
            return self.inner.get(key)
        with self._lock:
            return self._load(r[0], r[1]).get(r[2])

    def get_many(self, keys: list[str]) -> list[dict | None]:
        seen: dict = {}
        out = []
        with self._lock:
            for k in keys:
                r = self._route(k)
                out.append(self.inner.get(k) if r is None else self._load(r[0], r[1], seen).get(r[2]))
        # each caller gets its own copy, also when two keys share a pack
        return [None if d is None else json.loads(json.dumps(d)) for d in out]

    def put(self, key: str, doc: dict) -> None:
        r = self._route(key)
        if r is None:
            return self.inner.put(key, doc)
        with self._lock:
            docs = self._load(r[0], r[1])
            docs[r[2]] = doc
            self.inner.put(r[0], {"pack": 1, "docs": docs})

    def delete(self, key: str) -> None:
        r = self._route(key)
        if r is None:
            return self.inner.delete(key)
        with self._lock:
            docs = self._load(r[0], r[1])
            if r[2] in docs:
                del docs[r[2]]
                self.inner.put(r[0], {"pack": 1, "docs": docs})

    def _members(self, pack_key: str) -> list[str]:
        folder = pack_key[:-len(self._SUFFIX)]
        if folder.rsplit("/", 1)[1] in self.WHOLE:  # <folder>.pack.json
            return [f"{folder}/{n}" for n in self._load(pack_key, folder + "/")]
        base, day = folder.rsplit("/", 1)  # <folder>/<day>.pack.json
        return [f"{base}/{n}" for n in self._load(pack_key, f"{base}/{day}" if day != "other" else "")]

    def _is_pack(self, key: str) -> bool:
        if not key.endswith(self._SUFFIX):
            return False
        return bool(self._KEY.match(key[:-len(self._SUFFIX)] + "/x.json")
                    or self._KEY.match(key.rsplit("/", 1)[0] + "/x.json"))

    def list(self, prefix: str) -> list[str]:
        with self._lock:
            m = self._FOLDER.match(prefix)
            if m and m.group(2) in self.WHOLE:
                names = self._load(m.group(1) + self._SUFFIX, m.group(1) + "/")
                return sorted(f"{m.group(1)}/{n}" for n in names if n.startswith(m.group(3)))
            out: set[str] = set()
            for k in self.inner.list(prefix if not m else m.group(1) + "/"):
                if self._is_pack(k):
                    out.update(self._members(k))
                elif self._route(k) is not None:  # a record from before packs: take it in
                    r = self._route(k)
                    out.update(f"{k.rsplit('/', 1)[0]}/{n}" for n in self._load(r[0], r[1]))
                else:
                    out.add(k)
            return sorted(k for k in out if k.startswith(prefix))

    def delete_prefix(self, prefix: str) -> int:
        m = self._FOLDER.match(prefix)
        if m and m.group(2) in self.WHOLE and m.group(3) == "":
            with self._lock:
                n = len(self._load(m.group(1) + self._SUFFIX, m.group(1) + "/"))
                self.inner.put(m.group(1) + self._SUFFIX, {"pack": 1, "docs": {}})
                return n
        return super().delete_prefix(prefix)


def make_store(settings: Settings) -> Store:
    store = _make_store(settings)
    if settings.store == "s3" and getattr(settings, "store_packed", True):
        return PackedStore(store)
    return store


def _make_store(settings: Settings) -> Store:
    kind = settings.store
    if kind == "memory":
        return MemoryStore()
    if kind == "dir":
        return DirStore(settings.store_dir)
    if kind == "s3":
        if not settings.s3_bucket:
            raise RuntimeError("STORE=s3 needs S3_BUCKET")
        return S3Store(settings.s3_endpoint_url, settings.s3_bucket,
                       settings.s3_access_key, settings.s3_secret_key, settings.s3_region)
    raise RuntimeError(f"unknown STORE: {kind}")
