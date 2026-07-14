/**
 * ZIP 解压 Task — 使用 @ohos.zlib.unzipFile 解压 EPUB
 *
 * unzipFile 虽已废弃，但专为 ZIP 格式设计，比 decompressFile 更稳定。
 */
import { taskpool } from '@kit.ArkTS';
import zlib from '@ohos.zlib';
import fileFs from '@ohos.file.fs';

@Concurrent
export async function extractZipConcurrent(filePath: string, targetDir: string): Promise<void> {
  console.info('[ZipExtract] targetDir:', targetDir);
  if (!fileFs.accessSync(targetDir)) fileFs.mkdirSync(targetDir, true);
  await zlib.unzipFile(filePath, targetDir, {});
}
