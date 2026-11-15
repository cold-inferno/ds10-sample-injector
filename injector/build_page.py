"""Assemble the single-file injector: src/page.html + src/core.js + patches.json -> dist/.

Usage: python3 build_page.py   (run build_patches.py first when the patch changes)
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    page = open(os.path.join(HERE, "src", "page.html")).read()
    core = open(os.path.join(HERE, "src", "core.js")).read().replace('if (typeof module !== "undefined") module.exports = DS10;', "")
    patches = json.load(open(os.path.join(HERE, "patches.json")))
    assert "/*__CORE__*/" in page and "/*__PATCHES__*/" in page
    out = page.replace("/*__CORE__*/", core).replace("/*__PATCHES__*/", json.dumps(patches, separators=(",", ":")))
    os.makedirs(os.path.join(HERE, "dist"), exist_ok=True)
    path = os.path.join(HERE, "dist", "DS-10 Sample Injector.html")
    with open(path, "w") as f:
        f.write(out)
    print(f"wrote {path} ({len(out) // 1024} KB, versions: {', '.join(sorted(patches))})")


if __name__ == "__main__":
    main()
