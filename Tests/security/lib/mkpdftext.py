#!/usr/bin/python3 -I
# mkpdftext.py OUT KIND N [M]: builds a hostile (or ordinary) PDF whose cost is in its text operators. Standard library
# only, every stream Flate-compressed. KIND, N and M are explained next to each case in `build`.
import sys, zlib

LINE = b'il gatto dorme sul tavolo mentre la pioggia cade fuori dalla vecchia casa'

def text(s):
    return b'BT /F1 8 Tf 20 700 Td (' + s + b') Tj ET\n'

class PDF:
    def __init__(self):
        self.objects = []
    def add(self, body):
        self.objects.append(body)
        return len(self.objects)
    def reserve(self):
        return self.add(b'')
    def stream(self, data, extra=b'', num=None):
        z = zlib.compress(data, 9)
        body = b'<< ' + extra + b' /Filter /FlateDecode /Length %d >>\nstream\n' % len(z) + z + b'\nendstream'
        if num is None:
            return self.add(body)
        self.objects[num - 1] = body
        return num
    def write(self, out, root):
        chunks, offsets, position = [b'%PDF-1.5\n'], [], 9
        for i, body in enumerate(self.objects):
            piece = b'%d 0 obj\n' % (i + 1) + body + b'\nendobj\n'
            offsets.append(position)
            chunks.append(piece)
            position += len(piece)
        xref = b'xref\n0 %d\n0000000000 65535 f \n' % (len(self.objects) + 1)
        xref += b''.join(b'%010d 00000 n \n' % o for o in offsets)
        chunks.append(xref + b'trailer << /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(self.objects) + 1, root, position))
        with open(out, 'wb') as f:
            f.write(b''.join(chunks))

def document(pdf, out, pages, resources):
    """pages: a list of lists of content stream numbers."""
    tree = pdf.reserve()
    kids = []
    for contents in pages:
        refs = b' '.join(b'%d 0 R' % c for c in contents)
        kids.append(pdf.add(b'<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] /Contents [%s] /Resources %s >>' % (tree, refs, resources)))
    pdf.objects[tree - 1] = b'<< /Type /Pages /Count %d /Kids [%s] >>' % (len(kids), b' '.join(b'%d 0 R' % k for k in kids))
    pdf.write(out, pdf.add(b'<< /Type /Catalog /Pages %d 0 R >>' % tree))

FONT = b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'

def lzw(data):
    """PDF's LZW, EarlyChange 1."""
    out, bits, count = bytearray(), 0, 0
    def put(code, width):
        nonlocal bits, count
        bits = (bits << width) | code
        count += width
        while count >= 8:
            count -= 8
            out.append((bits >> count) & 0xFF)
        bits &= (1 << count) - 1
    table = {bytes([i]): i for i in range(256)}
    width, next_code = 9, 258
    put(256, width)
    current = b''
    for byte in data:
        grown = current + bytes([byte])
        if grown in table:
            current = grown
            continue
        put(table[current], width)
        table[grown] = next_code
        next_code += 1
        if next_code > (1 << width) - 1 and width < 12:
            width += 1
        if next_code >= 4094:
            put(256, width)
            table = {bytes([i]): i for i in range(256)}
            width, next_code = 9, 258
        current = bytes([byte])
    if current:
        put(table[current], width)
    put(257, width)
    if count:
        put(0, 8 - count)
    return bytes(out)

def build(out, kind, n, m):
    pdf = PDF()
    font = pdf.add(FONT)
    res = b'<< /Font << /F1 %d 0 R >> >>' % font
    if kind == 'righe':            # as the audit: N lines of text, each with one Tj
        pages = [[pdf.stream(text(LINE) * n)]]
    elif kind == 'caratteri':      # exactly N characters on one page, in strings of LINE's length (the limit tests)
        q, r = divmod(n, len(LINE))
        pages = [[pdf.stream(text(LINE) * q + (text(LINE[:r]) if r else b''))]]
    elif kind == 'tj':             # N TJ arrays, each of M strings of one character
        pages = [[pdf.stream((b'BT /F1 8 Tf 20 700 Td [' + b'(a) -5 ' * m + b'] TJ ET\n') * n)]]
    elif kind == 'somma':          # exactly N characters, split evenly over M pages
        each, extra = divmod(n, m)
        def body(count):
            q, r = divmod(count, len(LINE))
            return text(LINE) * q + (text(LINE[:r]) if r else b'')
        pages = [[pdf.stream(body(each + (1 if i < extra else 0)))] for i in range(m)]
    elif kind == 'stringa':        # one string of N characters
        pages = [[pdf.stream(text(b'a' * n))]]
    elif kind == 'invisibile':     # N lines drawn in render mode 3
        pages = [[pdf.stream(b'3 Tr\n' + text(LINE) * n)]]
    elif kind == 'apici':          # N lines through the ' and " operators
        body = b"BT /F1 8 Tf 20 700 Td 9 TL\n" + (b'(' + LINE + b") '\n" + b'0 0 (' + LINE + b') "\n') * (n // 2) + b'ET\n'
        pages = [[pdf.stream(body)]]
    elif kind == 'flussi':         # N content streams on the page, each of M lines
        one = pdf.stream(text(LINE) * m)
        pages = [[one] * n]
    elif kind == 'pagine':         # N pages, each of M lines: their sum is what counts
        pages = [[pdf.stream(text(LINE) * m)] for _ in range(n)]
    elif kind == 'forma':          # a form of M lines, drawn N times
        form = pdf.stream(text(LINE) * m, b'/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources %s' % res)
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /X %d 0 R >> >>' % (font, form)
        pages = [[pdf.stream(b'/X Do\n' * n)]]
    elif kind == 'annidata':       # N levels of forms, each drawing the one below M times; one line at the bottom
        below = pdf.stream(text(LINE), b'/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources %s' % res)
        for _ in range(n - 1):
            inner = b'<< /Font << /F1 %d 0 R >> /XObject << /X %d 0 R >> >>' % (font, below)
            below = pdf.stream(b'/X Do\n' * m, b'/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources %s' % inner)
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /X %d 0 R >> >>' % (font, below)
        pages = [[pdf.stream(b'/X Do\n' * m)]]
    elif kind == 'ciclo':          # a form that draws itself
        form = pdf.reserve()
        inner = b'<< /Font << /F1 %d 0 R >> /XObject << /X %d 0 R >> >>' % (font, form)
        pdf.stream(text(LINE) + b'/X Do\n', b'/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources %s' % inner, num=form)
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /X %d 0 R >> >>' % (font, form)
        pages = [[pdf.stream(b'/X Do\n')]]
    elif kind == 'type3':          # N lines in a Type 3 font whose glyph is itself M operators
        glyph = pdf.stream(b'1000 0 d0\n' + b'0 0 10 10 re f\n' * m)
        t3 = pdf.add(b'<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] '
                     b'/CharProcs << /a %d 0 R >> /Encoding << /Type /Encoding /Differences [97 /a] >> '
                     b'/FirstChar 97 /LastChar 97 /Widths [1000] >>' % glyph)
        res = b'<< /Font << /F1 %d 0 R >> >>' % t3
        pages = [[pdf.stream(b'BT /F1 8 Tf 20 700 Td (aaaaaaaa) Tj ET\n' * n)]]
    elif kind == 'tounicode':      # N lines; ToUnicode turns each byte into M characters
        cmap = (b'/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def /CMapType 2 def\n'
                b'1 begincodespacerange <00> <FF> endcodespacerange\n1 beginbfchar\n<61> <' + b'0041' * m + b'>\nendbfchar\n'
                b'endcmap CMapName currentdict /CMap defineresource pop end end\n')
        map_ = pdf.stream(cmap)
        special = pdf.add(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode %d 0 R >>' % map_)
        res = b'<< /Font << /F1 %d 0 R >> >>' % special
        pages = [[pdf.stream(text(b'a' * 70) * n)]]
    elif kind in ('toupesante', 'toubugiarda'):   # a ToUnicode map of N MB unpacked; the second lies about its length
        import random
        rng = random.Random(1)
        cmap = b'% ' + bytes(rng.getrandbits(8) & 0x7f | 0x20 for _ in range(400_000)) + b'\n' + b' ' * (n * 1_000_000)
        z = zlib.compress(cmap, 9)
        length = 100 if kind == 'toubugiarda' else len(z)
        map_ = pdf.add(b'<< /Filter /FlateDecode /Length %d >>\nstream\n' % length + z + b'\nendstream')
        special = pdf.add(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /ToUnicode %d 0 R >>' % map_)
        res = b'<< /Font << /F1 %d 0 R >> >>' % special
        pages = [[pdf.stream(text(LINE))]]
    elif kind == 'numerix':        # N numbers, each followed by a word that isn't an operator
        pages = [[pdf.stream(b'1 x ' * n)]]
    elif kind == 'stringhevuote':  # N empty strings and no operator
        pages = [[pdf.stream(b'() ' * n)]]
    elif kind == 'numeribinari':   # N numbers, each followed by a byte that isn't text
        pages = [[pdf.stream(b'1 \xff ' * n)]]
    elif kind == 'doppio':         # N numbers, Flate on Flate
        z = zlib.compress(zlib.compress(b'1 ' * n, 9), 9)
        pages = [[pdf.add(b'<< /Filter [/FlateDecode /FlateDecode] /Length %d >>\nstream\n' % len(z) + z + b'\nendstream')]]
    elif kind == 'a85':            # N numbers, ASCII85 on Flate (not seen by the check on streams: measured, not refused)
        import base64
        z = base64.a85encode(zlib.compress(b'1 ' * n, 9)) + b'~>'
        pages = [[pdf.add(b'<< /Filter [/ASCII85Decode /FlateDecode] /Length %d >>\nstream\n' % len(z) + z + b'\nendstream')]]
    elif kind in ('lzw', 'lzwnormale', 'lzwa85', 'a85normale', 'indiretto', 'hash', 'rl', 'ahx'):
        # N numbers (or N lines of ordinary text, the *normale ones) through filters the check on streams must follow
        import base64
        data = text(LINE) * n if kind.endswith('normale') else b'1 ' * n
        if kind == 'a85normale':
            z, f = base64.a85encode(zlib.compress(data, 9)) + b'~>', b'[/ASCII85Decode /FlateDecode]'
        elif kind == 'lzw' or kind == 'lzwnormale':
            z, f = lzw(data), b'/LZWDecode'
        elif kind == 'lzwa85':
            z, f = base64.a85encode(lzw(data)) + b'~>', b'[/A85 /LZW]'
        elif kind == 'indiretto':      # the filter is in another object
            z, f = base64.a85encode(zlib.compress(data, 9)) + b'~>', b'%d 0 R' % pdf.add(b'[/ASCII85Decode /FlateDecode]')
        elif kind == 'hash':           # the same name written with #xx
            z, f = base64.a85encode(zlib.compress(data, 9)) + b'~>', b'[/ASCII#385Decode /Fl#61teDecode]'
        elif kind == 'rl':
            z = b''.join(bytes([129, data[0]]) if False else bytes([1]) + data[i:i + 2] for i in range(0, 0)) or (bytes([129, 0x31, 129, 0x20]) * (n // 128) + b'\x80')
            f = b'/RunLengthDecode'
        else:                          # ahx
            z, f = zlib.compress(data, 9).hex().encode() + b'>', b'[/ASCIIHexDecode /FlateDecode]'
        pages = [[pdf.add(b'<< /Filter %s /Length %d >>\nstream\n' % (f, len(z)) + z + b'\nendstream')]]
    elif kind == 'immagine':       # a blank image of N MB on the page, one line of text
        side = int((n * 1_000_000) ** 0.5)
        image = pdf.stream(bytes(side * side), b'/Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray /BitsPerComponent 8' % (side, side))
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /I %d 0 R >> >>' % (font, image)
        pages = [[pdf.stream(b'q 612 0 0 792 0 0 cm /I Do Q\n' + text(LINE))]]
    elif kind == 'corti':          # N Tj of one character
        pages = [[pdf.stream(b'BT /F1 8 Tf 20 700 Td\n' + b'(a) Tj\n' * n + b'ET\n')]]
    elif kind == 'cortipagine':    # N pages, each of M Tj of one character
        pages = [[pdf.stream(b'BT /F1 8 Tf 20 700 Td\n' + b'(a) Tj\n' * m + b'ET\n')] for _ in range(n)]
    elif kind == 'formavuota':     # an empty form, drawn N times
        form = pdf.stream(b'', b'/Type /XObject /Subtype /Form /BBox [0 0 612 792]')
        res = b'<< /Font << /F1 %d 0 R >> /XObject << /X %d 0 R >> >>' % (font, form)
        pages = [[pdf.stream(b'/X Do\n' * n)]]
    elif kind == 'annot':          # N annotations on the page, each with M characters of contents
        note = pdf.add(b'<< /Type /Annot /Subtype /Text /Rect [0 0 9 9] /Contents (' + b'a' * m + b') >>')
        tree = pdf.reserve()
        arr = b' '.join([b'%d 0 R' % note] * n)
        page = pdf.add(b'<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] /Resources %s /Annots [%s] >>' % (tree, res, arr))
        pdf.objects[tree - 1] = b'<< /Type /Pages /Count 1 /Kids [%d 0 R] >>' % page
        pdf.write(out, pdf.add(b'<< /Type /Catalog /Pages %d 0 R >>' % tree))
        return
    elif kind == 'vuoti':          # N Tj of an empty string
        pages = [[pdf.stream(b'BT /F1 8 Tf 20 700 Td\n' + b'() Tj\n' * n + b'ET\n')]]
    elif kind == 'qq':             # N pairs of q and Q: no text at all
        pages = [[pdf.stream(b'q Q\n' * n)]]
    elif kind == 'numeri':         # N numbers and no operator at all
        pages = [[pdf.stream(b'1 ' * n)]]
    else:
        sys.exit('tipo sconosciuto: ' + kind)
    document(pdf, out, pages, res)

if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]) if len(sys.argv) > 4 else 1)
