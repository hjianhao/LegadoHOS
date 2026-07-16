/**
 * ZIP 解压 Task — 使用 @ohos.zlib.decompressFile 解压 EPUB
 */
import { taskpool } from '@kit.ArkTS';
import zlib from '@ohos.zlib';
import fileFs from '@ohos.file.fs';

@Concurrent
export async function extractZipConcurrent(filePath: string, targetDir: string): Promise<void> {
  console.info('[ZipExtract] targetDir:', targetDir);
  try {
    if (!fileFs.accessSync(targetDir)) {
      fileFs.mkdirSync(targetDir, true);
    }
  } catch (err) {
    throw new Error(`Prepare unzip directory failed: ${targetDir}: ${(err as Error).message}`);
  }
  try {
    await zlib.decompressFile(filePath, targetDir, {});
  } catch (err) {
    throw new Error(`Extract ZIP failed: ${filePath}: ${(err as Error).message}`);
  }
}
