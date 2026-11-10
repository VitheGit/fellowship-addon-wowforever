"""Turn CHANGELOG.md into CurseForge HTML: docs/curseforge-changelog-all.html (every version)
and docs/curseforge-changelog-<latest>.html (newest version only)."""
import html, re

def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
    return re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', t)

def convert(lines):
    out, inlist = [], False
    for l in lines:
        if l.startswith('# '):
            continue
        if not l.startswith('- ') and inlist:
            out.append('</ul>'); inlist = False
        if l.startswith('## '):
            out.append('<h2>' + inline(l[3:]) + '</h2>')
        elif l.startswith('### '):
            out.append('<h3>' + inline(l[4:]) + '</h3>')
        elif l.startswith('- '):
            if not inlist:
                out.append('<ul>'); inlist = True
            out.append('<li>' + inline(l[2:]) + '</li>')
        elif l.strip():
            out.append('<p>' + inline(l) + '</p>')
    if inlist:
        out.append('</ul>')
    return '\n'.join(out) + '\n'

lines = open('CHANGELOG.md', encoding='utf-8').read().splitlines()
open('docs/curseforge-changelog-all.html', 'w', encoding='utf-8').write(convert(lines))
heads = [i for i, l in enumerate(lines) if l.startswith('## ')]
latest = lines[heads[0]][3:].split()[0]
end = heads[1] if len(heads) > 1 else len(lines)
open('docs/curseforge-changelog-%s.html' % latest, 'w', encoding='utf-8').write(convert(lines[heads[0]:end]))
print('wrote all +', latest)
