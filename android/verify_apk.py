"""Artifact checks for an ARM64 ApriFinance APK; only Python stdlib is needed."""
from pathlib import Path
import struct
import sys
import zipfile


def verify(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'APK CRC failed'
        libraries = [n for n in archive.namelist() if n.startswith('lib/') and n.endswith('.so')]
        abis = {n.split('/')[1] for n in libraries}
        engines = {n.split('/')[1] for n in libraries if n.endswith('/libflutter.so')}
        assert abis == engines, f'Incomplete native architectures: libraries={abis}, engines={engines}'
        assert abis == {'arm64-v8a'}, f'Expected ARM64 artifact, got {abis}'
        for name in libraries:
            data = archive.read(name)
            assert data[:6] == b'\x7fELF\x02\x01', f'Expected little-endian ELF64: {name}'
            offset = struct.unpack_from('<Q', data, 32)[0]
            entry_size, count = struct.unpack_from('<HH', data, 54)
            alignments = [struct.unpack_from('<Q', data, offset + i * entry_size + 48)[0]
                          for i in range(count)
                          if struct.unpack_from('<I', data, offset + i * entry_size)[0] == 1]
            assert alignments and all(a >= 16384 for a in alignments), f'16 KiB incompatible ELF: {name}'
    return {'apk': path.name, 'passed': True, 'native_libraries': len(libraries),
            'abi': 'arm64-v8a', 'elf_16kb': True}


if __name__ == '__main__':
    print(verify(Path(sys.argv[1])))
