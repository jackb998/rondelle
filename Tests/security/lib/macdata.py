#!/usr/bin/python3 -I
# macdata.py FILE…: looks for data about this Mac in output files, in the raw bytes, in every ZIP member (DOCX, ODT)
# and in every PDF flate stream (XMP included). Prints «FILE<TAB>STRING» per hit, nothing if clean.
import getpass, os, re, subprocess, sys, zipfile, zlib

def run(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout.strip()

fixed = [run('sw_vers', '-buildVersion'), getpass.getuser(), run('id', '-F'), run('scutil', '--get', 'ComputerName'),
         run('scutil', '--get', 'LocalHostName'), run('hostname'), os.path.expanduser('~'),
         'Quartz', 'macOS', 'Mac OS X', 'Cocoa HTML', 'CocoaVersion', 'cocoartf', 'cocoaplatform', 'cocoatextscaling', 'AppKit', 'CocoaOOXMLWriter', 'CocoaODFWriter', 'Writer/']
version = run('sw_vers', '-productVersion')
needles = [n.encode() for n in fixed if n]
# A version alone is a number: only as a word, and not among a PDF page's coordinates.
version_word = re.compile(rb'(?<![\d.])' + re.escape(version.encode()) + rb'(?![\d.])')

def parts(path):
    data = open(path, 'rb').read()
    yield '', data
    if data[:2] == b'PK':
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                yield name + ': ', z.read(name)
    if data[:4] == b'%PDF':
        for m in re.finditer(rb'stream\r?\n(.*?)\r?\nendstream', data, re.S):
            try:
                yield 'flusso: ', zlib.decompress(m.group(1))
            except zlib.error:
                pass

status = 0
for path in sys.argv[1:]:
    is_pdf = open(path, 'rb').read(4) == b'%PDF'
    for where, data in parts(path):
        hits = [n.decode() for n in needles if n in data]
        if version_word.search(data) and not (is_pdf and where):
            hits.append(version)
        for hit in sorted(set(hits)):
            print(f'{os.path.basename(path)}\t{where}{hit}')
            status = 1
sys.exit(status)
