/**
 * ZIP CRC32 后台任务。
 *
 * 漫画导出时图片可能连续达到数十 MB，逐字节 CRC 如果在 ArkUI 主线程执行
 * 会触发 THREAD_BLOCK_6S。该函数只接收可转移的 ArrayBuffer，避免在主线程计算。
 */
import { taskpool } from '@kit.ArkTS';

@Concurrent
export function crc32Concurrent(input: ArrayBuffer): number {
  const table: Uint32Array = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c: number = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c >>> 0;
  }

  const data: Uint8Array = new Uint8Array(input);
  let crc: number = 0xFFFFFFFF;
  for (let i = 0; i < data.length; i++) {
    crc = (crc >>> 8) ^ table[(crc ^ data[i]) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}
