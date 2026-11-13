"""Synthetic PDF fixtures only; requires reportlab, Pillow, numpy and pypdf."""
import io
import pathlib
import sys
import numpy as np
from PIL import Image
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DictionaryObject, NameObject

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
scan = root / "Scan.pdf"
c = canvas.Canvas(str(scan), pagesize=(612, 792))
c.setTitle("DisquEZ Synthetic Scan")
for page in (1, 2):
    rng = np.random.default_rng(page)
    y, x = np.mgrid[:1400, :1000]
    rgb = np.stack([(x // 5 + y // 7 + page * channel * 31 + rng.integers(0, 32, x.shape)) % 256 for channel in (1, 2, 3)], axis=2).astype(np.uint8)
    buffer = io.BytesIO()
    Image.fromarray(rgb).save(buffer, format="PNG")
    c.drawImage(ImageReader(io.BytesIO(buffer.getvalue())), 40, 45, 532, 695)
    c.setFont("Helvetica", 20)
    c.drawString(40, 760, f"DisquEZ searchable page {page}")
    c.showPage()
c.save()
c = canvas.Canvas(str(root / "Text.pdf"), pagesize=(612, 792))
c.drawString(50, 740, "DisquEZ searchable text only")
c.save()
c = canvas.Canvas(str(root / "Form.pdf"), pagesize=(612, 792))
c.drawString(50, 740, "Synthetic interactive form - keep original")
c.acroForm.textfield(name="DisquEZField", value="Synthetic value", x=50, y=650, width=250, height=30)
c.showPage()
c.save()
w = PdfWriter(); w.clone_document_from_reader(PdfReader(scan)); w.encrypt("synthetic-password-only")
with (root / "Encrypted.pdf").open("wb") as file: w.write(file)
w = PdfWriter(); w.clone_document_from_reader(PdfReader(scan))
w._root_object[NameObject("/Perms")] = DictionaryObject({NameObject("/DocMDP"): DictionaryObject({NameObject("/Type"): NameObject("/Sig")})})
with (root / "SignatureStructure.pdf").open("wb") as file: w.write(file)
w = PdfWriter(); reader = PdfReader(scan); w.add_page(reader.pages[1]); w.add_page(reader.pages[0])
with (root / "Reordered.pdf").open("wb") as file: w.write(file)
w = PdfWriter(); w.clone_document_from_reader(PdfReader(scan)); w.pages[1].rotate(90)
with (root / "Rotated.pdf").open("wb") as file: w.write(file)
(root / "Corrupt.pdf").write_bytes(b"%PDF-1.7\nintentionally invalid synthetic PDF")
print("Generated 8 synthetic PDFs:", root)
