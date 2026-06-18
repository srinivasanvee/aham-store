import os
import tempfile
from contextlib import asynccontextmanager

import fitz                           # PyMuPDF — PDF
from docx import Document as DocxDoc  # python-docx — Word
from io import BytesIO
import ebooklib
from ebooklib import epub
from bs4 import BeautifulSoup
import chardet

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import PlainTextResponse
from google.cloud import storage, firestore

import vertexai
from vertexai.language_models import TextEmbeddingModel

ALLOWED_EXTENSIONS = {"pdf", "docx", "epub", "txt", "md"}
MAX_FILE_SIZE_BYTES = 50 * 1024 * 1024  # 50 MB
VERTEX_BATCH_SIZE = 250                  # Vertex AI embedding API limit

# Clients are initialised once at startup via the lifespan context,
# then reused across all requests.
storage_client: storage.Client
db: firestore.Client
embedder: TextEmbeddingModel


@asynccontextmanager
async def lifespan(app: FastAPI):
    global storage_client, db, embedder
    vertexai.init()
    storage_client = storage.Client()
    db = firestore.Client()
    embedder = TextEmbeddingModel.from_pretrained("text-embedding-005")
    yield


app = FastAPI(lifespan=lifespan)


# ---------------------------------------------------------------------------
# Text extraction
# ---------------------------------------------------------------------------

def extract_text(data: bytes, filename: str) -> str:
    ext = filename.lower().rsplit(".", 1)[-1]

    if ext == "pdf":
        doc = fitz.open(stream=data, filetype="pdf")
        return "\n".join(page.get_text() for page in doc)

    elif ext == "docx":
        return "\n".join(
            p.text for p in DocxDoc(BytesIO(data)).paragraphs if p.text.strip()
        )

    elif ext == "epub":
        # ebooklib requires a real file path, not a stream
        with tempfile.NamedTemporaryFile(suffix=".epub", delete=False) as tmp:
            tmp.write(data)
            tmp_path = tmp.name
        try:
            book = epub.read_epub(tmp_path)
            parts = [
                BeautifulSoup(item.get_content(), "html.parser").get_text(separator="\n")
                for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT)
            ]
            return "\n".join(parts)
        finally:
            os.unlink(tmp_path)

    else:  # txt / md — detect encoding
        encoding = chardet.detect(data)["encoding"] or "utf-8"
        return data.decode(encoding)


# ---------------------------------------------------------------------------
# Chunking + embedding
# ---------------------------------------------------------------------------

def chunk_text(text: str, size: int = 1000, overlap: int = 150) -> list[str]:
    out, i = [], 0
    while i < len(text):
        chunk = text[i : i + size]
        if chunk.strip():
            out.append(chunk)
        i += size - overlap
    return out


def embed_chunks(chunks: list[str]) -> list:
    embeddings = []
    for i in range(0, len(chunks), VERTEX_BATCH_SIZE):
        batch = embedder.get_embeddings(chunks[i : i + VERTEX_BATCH_SIZE])
        embeddings.extend(batch)
    return embeddings


# ---------------------------------------------------------------------------
# Firestore helpers
# ---------------------------------------------------------------------------

def delete_existing_vectors(user_id: str, source: str):
    col = db.collection("users").document(user_id).collection("vectors")
    old_docs = col.where("source", "==", source).stream()
    batch = db.batch()
    for doc in old_docs:
        batch.delete(doc.reference)
    batch.commit()


# ---------------------------------------------------------------------------
# Eventarc endpoint
# ---------------------------------------------------------------------------

@app.post("/", response_class=PlainTextResponse)
async def ingest(request: Request):
    # Eventarc delivers Cloud Storage events as JSON in the request body
    event = await request.json()
    bucket_name: str = event.get("bucket", "")
    name: str = event.get("name", "")  # expected format: {userId}/{filename}

    if not bucket_name or not name:
        raise HTTPException(status_code=400, detail="missing bucket or name in event payload")

    ext = name.lower().rsplit(".", 1)[-1]
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"unsupported file type: .{ext}")

    parts = name.split("/", 1)
    if len(parts) != 2:
        raise HTTPException(status_code=400, detail="object name must follow the pattern userId/filename")
    user_id, filename = parts

    doc_ref = (
        db.collection("users")
        .document(user_id)
        .collection("documents")
        .document(filename)
    )
    doc_ref.set({"status": "processing", "source": name})

    try:
        blob = storage_client.bucket(bucket_name).blob(name)
        blob.reload()

        if blob.size > MAX_FILE_SIZE_BYTES:
            doc_ref.set({"status": "failed", "error": f"file exceeds {MAX_FILE_SIZE_BYTES // (1024 * 1024)} MB limit"})
            raise HTTPException(status_code=400, detail=f"file too large: {blob.size} bytes")

        data = blob.download_as_bytes()
        text = extract_text(data, filename)
        chunks = chunk_text(text)

        if not chunks:
            doc_ref.set({"status": "failed", "error": "no text extracted from file"})
            raise HTTPException(status_code=422, detail="no text could be extracted")

        embeddings = embed_chunks(chunks)
        delete_existing_vectors(user_id, name)

        vectors_col = db.collection("users").document(user_id).collection("vectors")
        write_batch = db.batch()
        for chunk, embedding in zip(chunks, embeddings):
            ref = vectors_col.document()
            write_batch.set(ref, {
                "text": chunk,
                "embedding": firestore.Vector(embedding.values),
                "source": name,
                "user_id": user_id,
            })
        write_batch.commit()

        doc_ref.set({"status": "ready", "source": name, "chunks": len(chunks)})
        return "ok"

    except HTTPException:
        raise
    except Exception as exc:
        doc_ref.set({"status": "failed", "error": str(exc)})
        raise
