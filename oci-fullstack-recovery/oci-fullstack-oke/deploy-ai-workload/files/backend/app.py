import io
import os
import re
import time
from contextlib import closing
from pathlib import Path
from typing import Any

import httpx
import oracledb
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from pypdf import PdfReader

APP_NAME = "OCI AI FSDR Lab"
ADB_USER = os.environ["ADB_USER"]
ADB_PASSWORD = os.environ["ADB_PASSWORD"]
ADB_DSN = os.environ["ADB_DSN"]
ADB_WALLET_PASSWORD = os.environ["ADB_WALLET_PASSWORD"]
TNS_ADMIN = os.environ.get("TNS_ADMIN", "/opt/oracle/wallet")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen2.5:0.5b")
REGION = os.environ.get("OCI_REGION", "primary-region")
ACTIVE_DB_REGION = os.environ.get("ACTIVE_DB_REGION", "")
ADB_PRIMARY_REGION = os.environ.get("ADB_PRIMARY_REGION", "")
ADB_STANDBY_REGION = os.environ.get("ADB_STANDBY_REGION", "")

_database_region_cache = {"value": "unknown", "expires_at": 0.0}

STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "how", "i",
    "in", "is", "it", "of", "on", "or", "that", "the", "their", "this", "to",
    "was", "what", "when", "where", "which", "who", "why", "with", "you", "your",
}

SAMPLE_DOCUMENTS = [
    (
        "oci-full-stack-drs-overview.txt",
        "text/plain",
        """OCI Full Stack Disaster Recovery is an orchestration layer for validated recovery.
It coordinates application, database, network, storage, and Kubernetes resources after the underlying DR architecture and replication are already in place.
For a successful DR plan, define RTO and RPO first, then automate prechecks, switchovers, failovers, smoke tests, and reverse transitions.
Full Stack DR does not replace replication, backups, IAM, DNS, or application resiliency. It orchestrates the runbook you already designed and tested.
""",
    ),
    (
        "oke-ai-lab-notes.txt",
        "text/plain",
        """This lab demonstrates an AI workload on Oracle Kubernetes Engine.
The application uses a FastAPI backend, a web UI, and an in-cluster Ollama service.
Questions and answers are stored in Autonomous Database so the history survives application restarts and DR events.
Seeded documents are indexed automatically during deployment so the app is usable immediately after install.
""",
    ),
]

app = FastAPI(title=APP_NAME, version="1.3.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class ChatRequest(BaseModel):
    question: str = Field(min_length=1, max_length=4000)


class UploadResponse(BaseModel):
    document_id: int
    filename: str
    mime_type: str
    chunks_created: int
    characters: int


def db_connect(dsn: str | None = None) -> oracledb.Connection:
    return oracledb.connect(
        user=ADB_USER,
        password=ADB_PASSWORD,
        dsn=dsn or ADB_DSN,
        config_dir=TNS_ADMIN,
        wallet_location=TNS_ADMIN,
        wallet_password=ADB_WALLET_PASSWORD,
    )


def execute_ddl(cursor: oracledb.Cursor, ddl: str) -> None:
    try:
        cursor.execute(ddl)
    except oracledb.DatabaseError as exc:
        error = exc.args[0]
        if getattr(error, "code", None) != 955:
            raise


def column_exists(cursor: oracledb.Cursor, table_name: str, column_name: str) -> bool:
    cursor.execute(
        """
        SELECT COUNT(*)
        FROM user_tab_columns
        WHERE table_name = :1
          AND column_name = :2
        """,
        [table_name.upper(), column_name.upper()],
    )
    return int(cursor.fetchone()[0]) > 0


def ensure_column(cursor: oracledb.Cursor, table_name: str, column_name: str, ddl_fragment: str) -> None:
    if not column_exists(cursor, table_name, column_name):
        cursor.execute(f"ALTER TABLE {table_name} ADD ({ddl_fragment})")


def read_lob(value: Any) -> str:
    if value is None:
        return ""
    if hasattr(value, "read"):
        return value.read()
    return str(value)


def normalize_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def database_region_from_host(server_host: str) -> str:
    """Extract an OCI region such as eu-frankfurt-1 from the active DB server host."""
    match = re.search(r"(?:^|\.)([a-z]+-[a-z]+-\d+)(?:\.|$)", server_host.lower())
    return match.group(1) if match else "unknown"


def connection_hosts_for_alias(alias: str) -> list[str]:
    """Read the ordered TCPS hosts for an alias from the mounted wallet TNS file."""
    try:
        tnsnames = Path(TNS_ADMIN, "tnsnames.ora").read_text(encoding="utf-8")
    except OSError:
        return []
    block_match = re.search(
        rf"(?ims)^\s*{re.escape(alias)}\s*=\s*(.*?)(?=^\s*[A-Za-z0-9_.-]+\s*=|\Z)",
        tnsnames,
    )
    if not block_match:
        return []
    return re.findall(r"\(HOST\s*=\s*([^\)\s]+)\)", block_match.group(1), flags=re.IGNORECASE)


def connected_database_region(service_name: str, server_host: str) -> str:
    """Identify the writable primary, including when the standby is reachable."""
    if time.monotonic() < _database_region_cache["expires_at"]:
        return str(_database_region_cache["value"])

    regions = [region for region in (ADB_PRIMARY_REGION, ADB_STANDBY_REGION) if region]
    hosts = connection_hosts_for_alias(ADB_DSN)
    if len(regions) != len(hosts) or not service_name:
        detected = database_region_from_host(server_host)
        _database_region_cache.update(value=detected, expires_at=time.monotonic() + 30)
        return detected

    reachable: list[tuple[str, str, str, str]] = []
    for host, region in zip(hosts, regions):
        endpoint_dsn = (
            "(DESCRIPTION=(CONNECT_TIMEOUT=5)(TRANSPORT_CONNECT_TIMEOUT=2)(RETRY_COUNT=1)(RETRY_DELAY=1)"
            f"(ADDRESS=(PROTOCOL=tcps)(PORT=1522)(HOST={host}))"
            f"(CONNECT_DATA=(SERVICE_NAME={service_name}))"
            "(SECURITY=(SSL_SERVER_DN_MATCH=yes)))"
        )
        try:
            with closing(db_connect(endpoint_dsn)) as conn:
                with conn.cursor() as cursor:
                    cursor.execute("SELECT database_role, open_mode FROM v$database")
                    role, open_mode = cursor.fetchone()
                reachable.append((region, str(role), str(open_mode), host))
        except Exception:
            continue

    for region, role, open_mode, _host in reachable:
        if role == "PRIMARY" and open_mode == "READ WRITE":
            _database_region_cache.update(value=region, expires_at=time.monotonic() + 30)
            return region

    # Preserve useful behavior during a role transition, but do not claim a
    # read-only snapshot standby is the active primary.
    for region, role, open_mode, _host in reachable:
        if role == "PRIMARY":
            _database_region_cache.update(value=region, expires_at=time.monotonic() + 30)
            return region

    _database_region_cache.update(value="unknown", expires_at=time.monotonic() + 30)
    return "unknown"


def split_chunks(text: str, max_words: int = 180, overlap: int = 30) -> list[str]:
    words = normalize_whitespace(text).split()
    if not words:
        return []
    if overlap >= max_words:
        overlap = max_words // 2
    chunks: list[str] = []
    start = 0
    while start < len(words):
        end = min(len(words), start + max_words)
        chunk = " ".join(words[start:end]).strip()
        if chunk:
            chunks.append(chunk)
        if end >= len(words):
            break
        start = max(end - overlap, start + 1)
    return chunks


def extract_text_from_upload(filename: str, mime_type: str, data: bytes) -> str:
    lower_name = filename.lower()
    lower_mime = (mime_type or "").lower()
    if lower_name.endswith(".pdf") or lower_mime == "application/pdf":
        reader = PdfReader(io.BytesIO(data))
        pages = [page.extract_text() or "" for page in reader.pages]
        return normalize_whitespace("\n".join(pages))
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1", errors="ignore")


def create_schema() -> None:
    with closing(db_connect()) as conn:
        with conn.cursor() as cursor:
            execute_ddl(
                cursor,
                """
                CREATE TABLE ai_lab_messages (
                    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                    question CLOB NOT NULL,
                    answer CLOB NOT NULL,
                    model_name VARCHAR2(128) NOT NULL,
                    region_name VARCHAR2(128),
                    latency_ms NUMBER,
                    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
                )
                """,
            )
            execute_ddl(
                cursor,
                """
                CREATE TABLE ai_lab_documents (
                    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                    filename VARCHAR2(255) NOT NULL,
                    mime_type VARCHAR2(128) NOT NULL,
                    uploaded_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
                )
                """,
            )
            ensure_column(cursor, "ai_lab_documents", "uploaded_at", "uploaded_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL")
            execute_ddl(
                cursor,
                """
                CREATE TABLE ai_lab_document_chunks (
                    id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                    doc_id NUMBER NOT NULL,
                    chunk_index NUMBER NOT NULL,
                    chunk_text CLOB NOT NULL,
                    created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
                    CONSTRAINT ai_lab_document_chunks_fk
                        FOREIGN KEY (doc_id) REFERENCES ai_lab_documents(id)
                        ON DELETE CASCADE
                )
                """,
            )
        conn.commit()


def insert_document(conn: oracledb.Connection, filename: str, mime_type: str, text: str) -> dict[str, Any]:
    chunks = split_chunks(text)
    with conn.cursor() as cursor:
        doc_id_var = cursor.var(oracledb.DB_TYPE_NUMBER)
        cursor.execute(
            """
            INSERT INTO ai_lab_documents (filename, mime_type)
            VALUES (:1, :2)
            RETURNING id INTO :3
            """,
            [filename, mime_type, doc_id_var],
        )
        returned_id = doc_id_var.getvalue()
        # python-oracledb returns DML RETURNING values as a one-element list
        # in Thin mode. Normalize both list and scalar forms.
        if isinstance(returned_id, (list, tuple)):
            if not returned_id:
                raise RuntimeError("Oracle did not return the inserted document ID")
            returned_id = returned_id[0]
        doc_id = int(returned_id)
        for index, chunk in enumerate(chunks, start=1):
            cursor.execute(
                """
                INSERT INTO ai_lab_document_chunks (doc_id, chunk_index, chunk_text)
                VALUES (:1, :2, :3)
                """,
                [doc_id, index, chunk],
            )
    conn.commit()
    return {
        "document_id": doc_id,
        "filename": filename,
        "mime_type": mime_type,
        "chunks_created": len(chunks),
        "characters": len(text),
    }


def seed_documents_if_needed() -> None:
    with closing(db_connect()) as conn:
        with conn.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) FROM ai_lab_documents")
            count = int(cursor.fetchone()[0])
            if count > 0:
                return
        for filename, mime_type, text in SAMPLE_DOCUMENTS:
            insert_document(conn, filename, mime_type, text)


def load_chunk_rows() -> list[dict[str, Any]]:
    with closing(db_connect()) as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT
                    d.id,
                    d.filename,
                    d.mime_type,
                    c.chunk_index,
                    c.chunk_text
                FROM ai_lab_document_chunks c
                JOIN ai_lab_documents d ON d.id = c.doc_id
                ORDER BY d.id DESC, c.chunk_index ASC
                FETCH FIRST 500 ROWS ONLY
                """
            )
            rows = []
            for row in cursor:
                rows.append(
                    {
                        "doc_id": row[0],
                        "filename": row[1],
                        "mime_type": row[2],
                        "chunk_index": int(row[3]),
                        "chunk_text": read_lob(row[4]),
                    }
                )
            return rows


def score_chunk(question: str, chunk: str) -> int:
    tokens = [t for t in re.findall(r"[a-z0-9]+", question.lower()) if len(t) > 2 and t not in STOPWORDS]
    if not tokens:
        return 0
    chunk_text = chunk.lower()
    score = 0
    for token in set(tokens):
        occurrences = chunk_text.count(token)
        if occurrences:
            score += min(occurrences, 5)
    return score


def pick_relevant_chunks(question: str, limit: int = 4) -> list[dict[str, Any]]:
    rows = load_chunk_rows()
    scored = []
    for row in rows:
        row_score = score_chunk(question, row["chunk_text"])
        if row_score > 0:
            scored.append((row_score, row))
    if not scored:
        return rows[:limit]
    scored.sort(key=lambda item: (-item[0], item[1]["doc_id"], item[1]["chunk_index"]))
    return [item[1] for item in scored[:limit]]


def build_prompt(question: str, chunks: list[dict[str, Any]]) -> str:
    if chunks:
        context = "\n\n".join(
            f"Source: {item['filename']} (chunk {item['chunk_index']})\n{item['chunk_text']}"
            for item in chunks
        )
    else:
        context = "No relevant document chunks were found."

    return (
        "You are the assistant for an OCI hands-on lab. "
        "Use the retrieved document context first, then answer the question clearly and concisely. "
        "If the context is insufficient, say so explicitly.\n\n"
        f"Question: {question}\n\n"
        f"Retrieved context:\n{context}\n\n"
        "Answer:"
    )


@app.on_event("startup")
def startup() -> None:
    create_schema()
    seed_documents_if_needed()


@app.get("/health")
def health() -> dict[str, Any]:
    database = "down"
    model_server = "down"
    database_host = ""
    database_region = "unknown"
    try:
        with closing(db_connect()) as conn:
            with conn.cursor() as cursor:
                cursor.execute("SELECT SYS_CONTEXT('USERENV', 'SERVER_HOST') FROM dual")
                database_host = str(cursor.fetchone()[0] or "")
                cursor.execute("SELECT SYS_CONTEXT('USERENV', 'SERVICE_NAME') FROM dual")
                service_name = str(cursor.fetchone()[0] or "")
                database_region = ACTIVE_DB_REGION or connected_database_region(service_name, database_host)
        database = "up"
    except Exception:
        pass

    try:
        response = httpx.get(f"{OLLAMA_URL}/api/tags", timeout=5.0)
        response.raise_for_status()
        model_server = "up"
    except Exception:
        pass

    return {
        "status": "ok" if database == "up" and model_server == "up" else "degraded",
        "database": database,
        "database_region": database_region,
        "database_host": database_host,
        "ollama": model_server,
        "model": OLLAMA_MODEL,
        "region": REGION,
    }


@app.get("/documents")
def documents() -> list[dict[str, Any]]:
    with closing(db_connect()) as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT
                    d.id,
                    d.filename,
                    d.mime_type,
                    TO_CHAR(d.uploaded_at, 'YYYY-MM-DD HH24:MI:SS'),
                    (SELECT COUNT(*) FROM ai_lab_document_chunks c WHERE c.doc_id = d.id),
                    COALESCE(
                        (SELECT DBMS_LOB.SUBSTR(c.chunk_text, 240, 1)
                           FROM ai_lab_document_chunks c
                          WHERE c.doc_id = d.id
                            AND c.chunk_index = 1),
                        ''
                    )
                FROM ai_lab_documents d
                ORDER BY d.id DESC
                FETCH FIRST 50 ROWS ONLY
                """
            )
            return [
                {
                    "id": int(row[0]),
                    "filename": row[1],
                    "mime_type": row[2],
                    "uploaded_at": row[3],
                    "chunk_count": int(row[4]),
                    "preview": read_lob(row[5]),
                }
                for row in cursor
            ]


@app.post("/upload", response_model=UploadResponse)
async def upload_document(file: UploadFile = File(...)) -> UploadResponse:
    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")

    text = extract_text_from_upload(file.filename or "uploaded-document", file.content_type or "application/octet-stream", raw)
    if not text.strip():
        raise HTTPException(status_code=400, detail="Could not extract any text from the uploaded file")

    with closing(db_connect()) as conn:
        result = insert_document(conn, file.filename or "uploaded-document", file.content_type or "application/octet-stream", text)

    return UploadResponse(**result)


@app.post("/chat")
def chat(payload: ChatRequest) -> dict[str, Any]:
    started = time.perf_counter()
    chunks = pick_relevant_chunks(payload.question)
    prompt = build_prompt(payload.question, chunks)

    try:
        response = httpx.post(
            f"{OLLAMA_URL}/api/generate",
            json={"model": OLLAMA_MODEL, "prompt": prompt, "stream": False},
            timeout=180.0,
        )
        response.raise_for_status()
        body = response.json()
        answer = body.get("response", "").strip()
        if not answer:
            raise RuntimeError("Ollama returned an empty response")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Model request failed: {exc}") from exc

    latency_ms = round((time.perf_counter() - started) * 1000)

    try:
        with closing(db_connect()) as conn:
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    INSERT INTO ai_lab_messages
                        (question, answer, model_name, region_name, latency_ms)
                    VALUES (:1, :2, :3, :4, :5)
                    """,
                    [payload.question, answer, OLLAMA_MODEL, REGION, latency_ms],
                )
            conn.commit()
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Database write failed: {exc}") from exc

    return {
        "answer": answer,
        "model": OLLAMA_MODEL,
        "region": REGION,
        "latency_ms": latency_ms,
        "sources": [
            {
                "filename": item["filename"],
                "chunk_index": item["chunk_index"],
                "preview": item["chunk_text"][:200],
            }
            for item in chunks
        ],
    }


@app.get("/history")
def history() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with closing(db_connect()) as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT id, question, answer, model_name, region_name, latency_ms,
                       TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS')
                FROM ai_lab_messages
                ORDER BY id DESC
                FETCH FIRST 20 ROWS ONLY
                """
            )
            for row in cursor:
                rows.append(
                    {
                        "id": row[0],
                        "question": read_lob(row[1]),
                        "answer": read_lob(row[2]),
                        "model": row[3],
                        "region": row[4],
                        "latency_ms": row[5],
                        "created_at": row[6],
                    }
                )
    return rows
