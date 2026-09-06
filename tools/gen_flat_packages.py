#!/data/data/com.termux/files/usr/bin/python3
"""gen_flat_packages.py — generate a flat APT Packages index from GitHub release .deb assets.

Mode 1 (release): --release REPO --tag TAG --assets ASSETS_FILE
  ASSETS_FILE has lines: ASSET_ID ASSET_NAME SIZE SHA256
  Downloads only the tiny control.tar.xz member from each .deb (range request)
  to extract control fields; uses the pre-known SHA256+Size from the asset metadata.
  This avoids downloading the full multi-MB .deb files.

Mode 2 (local): --latest-only [--out OUT] DEB [DEB...]
  Reads local .deb files (original mode).

With --latest-only, keeps only the newest version per Package name.
Filename is written as the BARE deb filename (apt joins the base URL + Filename).
"""
import sys, os, gzip, hashlib, tarfile, io, re, subprocess, tempfile

def read_control_from_deb(data):
    """Extract control fields from .deb binary data (ar archive bytes)."""
    if not data.startswith(b'!<arch>\n'):
        raise ValueError('not an ar archive')
    pos = 8
    while pos + 60 <= len(data):
        name = data[pos:pos + 16].decode('ascii', 'replace').strip()
        size = int(data[pos + 48:pos + 58].decode('ascii', 'replace').strip() or 0)
        body = data[pos + 60:pos + 60 + size]
        if name.startswith('control.tar.'):
            kind = name
            mode = 'r:xz' if kind.endswith('xz') else 'r:gz'
            tf = tarfile.open(fileobj=io.BytesIO(body), mode=mode)
            member = None
            for cand in ('./control', 'control'):
                try:
                    member = tf.extractfile(cand)
                except KeyError:
                    member = None
                if member is not None:
                    break
            if member is None:
                tf.close()
                raise ValueError('no control file in deb')
            ctrl = member.read().decode('utf-8', 'replace')
            tf.close()
            fields = {}
            for line in ctrl.splitlines():
                if ': ' in line and not line.startswith((' ', chr(9))):
                    k, _, v = line.partition(': ')
                    fields[k] = v.strip()
            return fields
        pos = pos + 60 + size + (size % 2)
    raise ValueError('no control member found')

def read_control_from_deb_path(deb):
    """Read full .deb and extract control fields."""
    with open(deb, 'rb') as f:
        data = f.read()
    return read_control_from_deb(data)

def download_control_from_release(repo, asset_id, asset_name):
    """Download only the first 128KB of a .deb to get the control.tar member.
    The ar header + control.tar.xz is always at the start of the file.
    Falls back to 512KB if 128KB isn't enough."""
    tmpdir = os.environ.get('TMPDIR', os.path.expanduser('~/tmp'))
    os.makedirs(tmpdir, exist_ok=True)
    temp = os.path.join(tmpdir, '_ctrl_%s' % asset_name)
    try:
        # Try downloading just the first 128KB via gh api (control.tar is tiny)
        subprocess.run(
            ['gh', 'api', f'repos/{repo}/releases/assets/{asset_id}',
             '-H', 'Accept: application/octet-stream',
             '-H', 'Range: bytes=0-131071'],
            stdout=open(temp, 'wb'), stderr=subprocess.DEVNULL, check=True, timeout=30
        )
        with open(temp, 'rb') as f:
            data = f.read()
        # The control.tar might be truncated at 128KB boundary. Try parsing.
        try:
            fields = read_control_from_deb(data)
            return fields
        except (ValueError, Exception):
            # Truncated — need more data. Download first 512KB.
            subprocess.run(
                ['gh', 'api', f'repos/{repo}/releases/assets/{asset_id}',
                 '-H', 'Accept: application/octet-stream',
                 '-H', 'Range: bytes=0-524287'],
                stdout=open(temp, 'wb'), stderr=subprocess.DEVNULL, check=True, timeout=60
            )
            with open(temp, 'rb') as f:
                data = f.read()
            return read_control_from_deb(data)
    finally:
        try:
            os.unlink(temp)
        except OSError:
            pass

def version_key(ver):
    """Sort key for version strings (sort -V like)."""
    try:
        from packaging.version import Version
        return (0, Version(ver))
    except Exception:
        pass
    parts = []
    for seg in re.split(r'([0-9]+)', ver):
        if seg.isdigit():
            parts.append((0, int(seg), ''))
        else:
            parts.append((1, 0, seg))
    return (1, tuple(parts))

def main():
    import argparse
    parser = argparse.ArgumentParser(description='Generate flat APT Packages index')
    sub = parser.add_subparsers(dest='mode')

    # Release mode
    rp = sub.add_parser('release', help='Generate from GitHub release assets')
    rp.add_argument('--repo', required=True, help='GitHub repo slug (e.g. Hope2333/codegraph-termux)')
    rp.add_argument('--tag', required=True, help='Release tag')
    rp.add_argument('--assets-file', required=True, help='File with lines: ASSET_ID ASSET_NAME SIZE SHA256')
    rp.add_argument('--out', default='Packages.gz', help='Output file')
    rp.add_argument('--base-url', default='', help='Base URL for Filename field')

    # Local mode
    lp = sub.add_parser('local', help='Generate from local .deb files')
    lp.add_argument('debs', nargs='*', help='.deb file paths')
    lp.add_argument('--out', default='Packages.gz', help='Output file')
    lp.add_argument('--latest-only', action='store_true')
    lp.add_argument('--base-url', default='', help='Base URL for Filename field')

    args = parser.parse_args()

    if args.mode is None:
        parser.print_help()
        return 1

    stanzas = []

    if args.mode == 'release':
        with open(args.assets_file) as f:
            asset_lines = [l.strip() for l in f if l.strip()]

        entries = {}  # pkg -> (fields, asset_id, asset_name, size, sha256)
        for line in asset_lines:
            parts = line.split(' ', 3)
            if len(parts) < 4:
                continue
            asset_id, asset_name, size, sha256 = parts
            print('  Parsing control from %s...' % asset_name, file=sys.stderr)
            try:
                fields = download_control_from_release(args.repo, asset_id, asset_name)
            except Exception as e:
                print('  WARN skip %s: %s' % (asset_name, e), file=sys.stderr)
                continue
            pkg = fields.get('Package', '')
            ver = fields.get('Version', '')
            if not pkg:
                continue
            entries[pkg] = (fields, asset_id, asset_name, int(size), sha256)

        for pkg in sorted(entries.keys()):
            f, _, asset_name, size, sha256 = entries[pkg]
            stanzas.append('\n'.join([
                'Package: %s' % f.get('Package', ''),
                'Version: %s' % f.get('Version', ''),
                'Architecture: %s' % f.get('Architecture', 'aarch64'),
                'Installed-Size: %s' % f.get('Installed-Size', '0'),
                'Depends: %s' % f.get('Depends', ''),
                'Description: %s' % f.get('Description', ''),
                'Filename: %s' % asset_name,
                'Size: %d' % size,
                'SHA256: %s' % sha256,
            ]) + '\n')

    elif args.mode == 'local':
        entries = {}
        for deb in args.debs:
            if not os.path.isfile(deb):
                continue
            try:
                f = read_control_from_deb_path(deb)
            except Exception as e:
                print('WARN skip %s: %s' % (deb, e), file=sys.stderr)
                continue
            pkg = f.get('Package', '')
            ver = f.get('Version', '')
            if not pkg:
                continue
            if args.latest_only:
                if pkg not in entries or version_key(ver) > version_key(entries[pkg][0].get('Version', '')):
                    entries[pkg] = (f, deb)
            else:
                entries[(pkg, ver)] = (f, deb)

        for key in sorted(entries.keys()):
            f, deb = entries[key]
            deb_name = os.path.basename(deb)
            h = hashlib.sha256()
            sz = 0
            with open(deb, 'rb') as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b''):
                    h.update(chunk)
                    sz += len(chunk)
            stanzas.append('\n'.join([
                'Package: %s' % f.get('Package', ''),
                'Version: %s' % f.get('Version', ''),
                'Architecture: %s' % f.get('Architecture', 'aarch64'),
                'Installed-Size: %s' % f.get('Installed-Size', '0'),
                'Depends: %s' % f.get('Depends', ''),
                'Description: %s' % f.get('Description', ''),
                'Filename: %s' % deb_name,
                'Size: %d' % sz,
                'SHA256: %s' % h.hexdigest(),
            ]) + '\n')

    if not stanzas:
        print('ERROR: no valid packages found', file=sys.stderr)
        return 1

    blob = ''.join(stanzas).encode()
    tmp = args.out + '.tmp'
    with gzip.open(tmp, 'wb', compresslevel=9) as g:
        g.write(blob)
    os.replace(tmp, args.out)
    print('PACKAGES_INDEX entries=%d bytes=%d out=%s' % (len(stanzas), os.path.getsize(args.out), args.out))
    return 0

if __name__ == '__main__':
    sys.exit(main())
