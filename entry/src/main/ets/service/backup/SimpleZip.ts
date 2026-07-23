/**
 * 最小 ZIP 写入器（STORE，无压缩）
 * 用于把多个文本/二进制文件打成标准 ZIP，兼容 Android 解压。
 */
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';

interface ZipEntry {
  name: string;
  data: Uint8Array;
  crc: number;
  offset: number;
}

export class SimpleZip {
  private entries: ZipEntry[] = [];

  addText(name: string, text: string): void {
    const encoder = new util.TextEncoder();
    const data = encoder.encodeInto(text);
    this.addBytes(name, data);
  }

  addBytes(name: string, data: Uint8Array): void {
    const normalized = name.replace(/\\/g, '/').replace(/^\/+/, '');
    this.entries.push({
      name: normalized,
      data: data,
      crc: SimpleZip.crc32(data),
      offset: 0,
    });
  }

  addFile(name: string, filePath: string): void {
    const stat = fileFs.statSync(filePath);
    const buf = new ArrayBuffer(stat.size);
    const file = fileFs.openSync(filePath, fileFs.OpenMode.READ_ONLY);
    try {
      fileFs.readSync(file.fd, buf);
    } finally {
      fileFs.closeSync(file);
    }
    this.addBytes(name, new Uint8Array(buf));
  }

  /** 写出 zip 到目标路径 */
  writeTo(zipPath: string): void {
    const chunks: Uint8Array[] = [];
    let offset = 0;
    // local files
    for (const entry of this.entries) {
      entry.offset = offset;
      const nameBytes = SimpleZip.utf8(entry.name);
      const local = new Uint8Array(30 + nameBytes.length);
      const view = new DataView(local.buffer);
      view.setUint32(0, 0x04034b50, true);
      view.setUint16(4, 20, true); // version needed
      view.setUint16(6, 0x0800, true); // utf-8 flag
      view.setUint16(8, 0, true); // store
      view.setUint16(10, 0, true);
      view.setUint16(12, 0, true);
      view.setUint32(14, entry.crc >>> 0, true);
      view.setUint32(18, entry.data.length, true);
      view.setUint32(22, entry.data.length, true);
      view.setUint16(26, nameBytes.length, true);
      view.setUint16(28, 0, true);
      local.set(nameBytes, 30);
      chunks.push(local);
      chunks.push(entry.data);
      offset += local.length + entry.data.length;
    }
    const centralStart = offset;
    // central directory
    for (const entry of this.entries) {
      const nameBytes = SimpleZip.utf8(entry.name);
      const central = new Uint8Array(46 + nameBytes.length);
      const view = new DataView(central.buffer);
      view.setUint32(0, 0x02014b50, true);
      view.setUint16(4, 20, true);
      view.setUint16(6, 20, true);
      view.setUint16(8, 0x0800, true);
      view.setUint16(10, 0, true);
      view.setUint16(12, 0, true);
      view.setUint16(14, 0, true);
      view.setUint32(16, entry.crc >>> 0, true);
      view.setUint32(20, entry.data.length, true);
      view.setUint32(24, entry.data.length, true);
      view.setUint16(28, nameBytes.length, true);
      view.setUint16(30, 0, true);
      view.setUint16(32, 0, true);
      view.setUint16(34, 0, true);
      view.setUint16(36, 0, true);
      view.setUint32(38, 0, true);
      view.setUint32(42, entry.offset, true);
      central.set(nameBytes, 46);
      chunks.push(central);
      offset += central.length;
    }
    const centralSize = offset - centralStart;
    const end = new Uint8Array(22);
    const endView = new DataView(end.buffer);
    endView.setUint32(0, 0x06054b50, true);
    endView.setUint16(4, 0, true);
    endView.setUint16(6, 0, true);
    endView.setUint16(8, this.entries.length, true);
    endView.setUint16(10, this.entries.length, true);
    endView.setUint32(12, centralSize, true);
    endView.setUint32(16, centralStart, true);
    endView.setUint16(20, 0, true);
    chunks.push(end);

    const total = chunks.reduce((s, c) => s + c.length, 0);
    const out = new Uint8Array(total);
    let p = 0;
    for (const c of chunks) {
      out.set(c, p);
      p += c.length;
    }
    let file: fileFs.File | null = null;
    try {
      try { fileFs.unlinkSync(zipPath); } catch (_e) { /* ok */ }
      file = fileFs.openSync(zipPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY | fileFs.OpenMode.TRUNC);
      fileFs.writeSync(file.fd, out.buffer);
    } finally {
      if (file) {
        try { fileFs.closeSync(file); } catch { /* ignore */ }
      }
    }
  }

  private static utf8(s: string): Uint8Array {
    return new util.TextEncoder().encodeInto(s);
  }

  private static crc32(buf: Uint8Array): number {
    let crc = 0xffffffff;
    for (let i = 0; i < buf.length; i++) {
      crc ^= buf[i];
      for (let j = 0; j < 8; j++) {
        const mask = -(crc & 1);
        crc = (crc >>> 1) ^ (0xedb88320 & mask);
      }
    }
    return (crc ^ 0xffffffff) >>> 0;
  }
}
