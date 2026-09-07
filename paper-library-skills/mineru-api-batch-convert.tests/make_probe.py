"""Create a public, synthetic two-page PDF; no paper-library input is read."""
import argparse
import zlib
from pathlib import Path


def make_pdf(path):
    objects = []
    def obj(data):
        objects.append(data if isinstance(data, bytes) else data.encode('ascii'))
    def stream(data, extra=''):
        return f'<< /Length {len(data)} {extra} >>\nstream\n'.encode() + data + b'\nendstream'
    obj('<< /Type /Catalog /Pages 2 0 R >>')
    obj('<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>')
    for content in (6, 7):
        obj(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 8 0 R >> >> /Contents {content} 0 R >>')
    obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    for page in (1, 2):
        text = f'BT /F1 18 Tf 50 740 Td (Synthetic MinerU performance probe - page {page}) Tj /F1 12 Tf 0 -35 Td (This is generated test data, not a scientific paper.) Tj 0 -30 Td (Equation: E = m c^2. Expected answer: 42.) Tj 0 -30 Td (Sample     Pressure     Flow) Tj 0 -20 Td (A                 10             2) Tj 0 -20 Td (B                 20             4) Tj 0 -30 Td (Figure 1. A red and blue checkerboard.) Tj ET\nq 240 0 0 160 50 280 cm /Im1 Do Q\n'
        obj(stream(text.encode('ascii')))
    pixels = bytes(v for y in range(32) for x in range(48) for v in ((220, 50, 50) if (x//8+y//8)%2 else (30, 70, 220)))
    obj(stream(zlib.compress(pixels), '/Type /XObject /Subtype /Image /Width 48 /Height 32 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode'))
    output = bytearray(b'%PDF-1.4\n')
    offsets = [0]
    for index, data in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f'{index} 0 obj\n'.encode() + data + b'\nendobj\n')
    start = len(output)
    output.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        output.extend(f'{offset:010} 00000 n \n'.encode())
    output.extend(f'trailer << /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('output')
    make_pdf(Path(parser.parse_args().output))
