#!/usr/bin/env python3
"""把两个 per-ABI release APK 合并成单包（双 ABI fat APK）。

Flutter 的 .so 在 APK 里是 deflate 压缩（extractNativeLibs=true），
重新打包不影响安装与对齐。签名在合并后由 apksigner 重签。

用法：python3 merge_apk.py <arm64.apk> <armeabi-v7a.apk> <out.apk>
"""
import sys
import zipfile


def is_sig(name: str) -> bool:
    return (
        name.startswith("META-INF/")
        and (
            name.endswith(".RSA")
            or name.endswith(".SF")
            or name.endswith(".DSA")
            or name.endswith(".EC")
        )
    )


def main() -> None:
    base, extra, out = sys.argv[1], sys.argv[2], sys.argv[3]
    written = set()
    with zipfile.ZipFile(base) as zb, zipfile.ZipFile(extra) as ze:
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zo:
            for zi in zb.infolist():
                if is_sig(zi.filename):
                    continue
                zo.writestr(zi, zb.read(zi.filename))
                written.add(zi.filename)
            for zi in ze.infolist():
                if zi.filename in written or is_sig(zi.filename):
                    continue
                zo.writestr(zi, ze.read(zi.filename))
                written.add(zi.filename)
    abis = sorted({n.split("/")[1] for n in written if n.startswith("lib/")})
    print(f"merged -> {out} abis={abis} entries={len(written)}")


if __name__ == "__main__":
    main()
