/**
 * TTS 模型文件下载与管理
 *
 * 支持多模型:
 *   - kokoro: Kokoro INT8 (HuggingFace, ~215 MB, 103 speakers, 24000 Hz)
 *   - vits:   VITS zh-ll (GitHub Release, ~117 MB, 5 speakers, 16000 Hz)
 *
 * 下载策略: 逐文件下载（从 HuggingFace API 获取文件列表）
 */

import common from '@ohos.app.ability.common';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';

// ---- 模型类型 ----

export type TtsModelType = 'kokoro' | 'vits';

// ---- 模型元信息 ----

interface ModelMeta {
  type: TtsModelType;
  dirName: string;
  label: string;
  desc: string;
  estimatedSize: number;
  sampleRate: number;
  speakers: number;
  hfRepo: string;
  requiredFiles: string[];
}

function getMeta(type: TtsModelType): ModelMeta {
  switch (type) {
    case 'vits': return VITS_META;
    default: return KOKORO_META;
  }
}

const KOKORO_META: ModelMeta = {
  type: 'kokoro',
  dirName: 'kokoro-int8-multi-lang-v1_1',
  label: '自然语音（高品质）',
  desc: 'Kokoro 多音色 · 103 个 speaker · 完全离线',
  estimatedSize: 230 * 1024 * 1024,
  sampleRate: 24000,
  speakers: 103,
  hfRepo: 'csukuangfj/kokoro-int8-multi-lang-v1_1',
  requiredFiles: ['model.int8.onnx', 'voices.bin', 'tokens.txt', 'lexicon-zh.txt'],
};

const VITS_META: ModelMeta = {
  type: 'vits',
  dirName: 'sherpa-onnx-vits-zh-ll',
  label: '自然语音（流畅）',
  desc: 'VITS 5 音色 · 轻量快速 · 完全离线',
  estimatedSize: 130 * 1024 * 1024,
  sampleRate: 16000,
  speakers: 5,
  hfRepo: 'csukuangfj/sherpa-onnx-vits-zh-ll',
  requiredFiles: ['model.onnx', 'tokens.txt', 'lexicon.txt'],
};

/** 国内镜像（优先使用） */
const USE_MIRROR = true;
const HF_API_BASE = USE_MIRROR ? 'https://hf-mirror.com/api/models' : 'https://huggingface.co/api/models';
const HF_RESOLVE_BASE = USE_MIRROR ? 'https://hf-mirror.com' : 'https://huggingface.co';

/** HTTP 超时 */
const HTTP_TIMEOUT = 60000;

/** HF API 返回的文件条目 */
interface HfFileEntry {
  rfilename: string;
  size?: number;
}

/** 取消标记 */
export interface CancelFlag {
  cancelled: boolean;
}

/** 每块大小：10 MB */
const CHUNK_SIZE = 10 * 1024 * 1024;

// ---- 公开 API ----

export class TtsModelManager {

  /** 获取模型元信息 */
  static getMeta(type: TtsModelType): ModelMeta {
    return getMeta(type);
  }

  /** 获取模型在沙箱中的路径 */
  static getModelPath(context: common.Context, type: TtsModelType): string {
    return `${context.filesDir}/tts/${getMeta(type).dirName}`;
  }

  /** 检查模型是否已就绪 */
  static async isModelReady(modelPath: string, type: TtsModelType): Promise<boolean> {
    const files = getMeta(type).requiredFiles;
    try {
      for (const file of files) {
        const stat = await fs.stat(`${modelPath}/${file}`);
        if (stat.size === 0) return false;
        // ONNX 模型: 检查文件头前 4 字节非全零（捕获损坏文件）
        if (file.endsWith('.onnx')) {
          if (stat.size < 1024 * 1024) return false; // 完整模型 >= 1MB
          const fp = await fs.open(`${modelPath}/${file}`, fs.OpenMode.READ_ONLY);
          try {
            const buf = new ArrayBuffer(4);
            await fs.read(fp.fd, buf);
            const view = new DataView(buf);
            if (view.getUint32(0, true) === 0) return false; // 全零 = 损坏
          } finally {
            await fs.close(fp);
          }
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static formatSize(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) return (bytes / (1024 * 1024 * 1024)).toFixed(1) + ' GB';
    if (bytes >= 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(0) + ' MB';
    if (bytes >= 1024) return (bytes / 1024).toFixed(0) + ' KB';
    return bytes + ' B';
  }



  // ---- 模型下载 ----

  static async downloadModel(
    context: common.Context,
    type: TtsModelType,
    onProgress?: (percent: number, status: string) => void,
    cancelFlag?: CancelFlag,
    forceRedownload?: boolean,
  ): Promise<string> {
    const meta = getMeta(type);
    const modelPath = TtsModelManager.getModelPath(context, type);
    await TtsModelManager.ensureDir_(modelPath);

    // 1. 获取文件列表
    onProgress?.(0, '正在获取文件列表...');
    let files: HfFileEntry[];
    if (type === 'vits') {
      // VITS 模型 HF API 响应慢且 size=0，使用预设文件列表
      files = TtsModelManager.vitsFileList_();
    } else {
      files = await TtsModelManager.fetchFileList_(meta.hfRepo);
    }
    const totalFiles = files.length;

    if (totalFiles === 0) {
      throw new Error('无法获取模型文件列表，请检查网络连接');
    }

    console.info('[TtsModel] downloading ' + totalFiles + ' files for ' + type);

    // 2. 逐文件下载
    let downloaded = 0;
    let skipped = 0;

    // 强制重新下载时先清空
    if (forceRedownload) {
      try { await TtsModelManager.deleteDir_(modelPath); } catch (_) {}
      await TtsModelManager.ensureDir_(modelPath);
    }

    for (let i = 0; i < files.length; i++) {
      if (cancelFlag?.cancelled) {
        throw new Error('下载已取消');
      }

      const file = files[i];
      const filePath = `${modelPath}/${file.rfilename}`;

      // 已下载则跳过
      try {
        const stat = await fs.stat(filePath);
        if (stat.size > 0) {
          skipped++;
          downloaded++;
          const pct = Math.round((downloaded / totalFiles) * 100);
          onProgress?.(pct, `下载中 ${downloaded}/${totalFiles}（已跳过 ${skipped} 个）`);
          continue;
        }
      } catch (_) { /* need download */ }

      // 确保父目录存在
      const parentDir = filePath.substring(0, filePath.lastIndexOf('/'));
      await TtsModelManager.ensureDir_(parentDir);

      // 下载
      const url = `${HF_RESOLVE_BASE}/${meta.hfRepo}/resolve/main/${file.rfilename}`;
      const useChunked = TtsModelManager.needsChunked_(file.size);
      await TtsModelManager.downloadFile_(url, filePath, 3, '', useChunked);

      downloaded++;
      const pct = Math.round((downloaded / totalFiles) * 100);
      const status = `下载中 ${downloaded}/${totalFiles}` +
        (skipped > 0 ? `（已跳过 ${skipped} 个）` : '');
      onProgress?.(pct, status);
    }

    // 3. 校验
    onProgress?.(100, '正在校验文件...');
    const ready = await TtsModelManager.isModelReady(modelPath, type);
    if (!ready) {
      throw new Error('模型下载不完整，关键文件缺失，请重新下载');
    }

    console.info('[TtsModel] download complete for ' + type + ', ' + downloaded + ' files');
    onProgress?.(100, '下载完成');
    return modelPath;
  }

  // ---- 清理 ----

  static async removeModel(modelPath: string): Promise<void> {
    try {
      await TtsModelManager.deleteDir_(modelPath);
    } catch (e) {
      console.error('[TtsModel] removeModel failed: ' + (e as Error).message);
      throw new Error('删除模型失败: ' + (e as Error).message);
    }
  }

  // ---- 内部: 文件列表 ----

  private static async fetchFileList_(hfRepo: string): Promise<HfFileEntry[]> {
    const apiUrl = `${HF_API_BASE}/${hfRepo}`;

    console.info('[TtsModel] fetching file list: ' + apiUrl);
    const httpRequest = http.createHttp();
    let resp: http.HttpResponse;
    try {
      resp = await httpRequest.request(apiUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: HTTP_TIMEOUT,
        readTimeout: HTTP_TIMEOUT,
      });
    } catch (err) {
      throw new Error('获取模型文件列表失败: ' + (err as Error).message);
    } finally {
      httpRequest.destroy();
    }

    if (resp.responseCode !== 200) {
      throw new Error('HTTP ' + resp.responseCode);
    }

    const body = resp.result as string;
    const json = JSON.parse(body) as Record<string, Object>;
    const siblings = json['siblings'] as HfFileEntry[];
    if (!siblings || siblings.length === 0) {
      throw new Error('模型文件列表为空');
    }

    console.info('[TtsModel] got ' + siblings.length + ' files');
    return siblings;
  }

  /** VITS 模型文件列表（预设，跳过 HF API 调用） */
  private static vitsFileList_(): HfFileEntry[] {
    const files: HfFileEntry[] = [
      { rfilename: 'model.onnx' },
      { rfilename: 'lexicon.txt' },
      { rfilename: 'tokens.txt' },
      { rfilename: 'date.fst' },
      { rfilename: 'number.fst' },
      { rfilename: 'phone.fst' },
      { rfilename: 'G_multisperaker_latest.json' },
      { rfilename: 'new_heteronym.fst' },
      { rfilename: 'dict/README.md' },
      { rfilename: 'dict/hmm_model.utf8' },
      { rfilename: 'dict/idf.utf8' },
      { rfilename: 'dict/jieba.dict.utf8' },
      { rfilename: 'dict/pos_dict/char_state_tab.utf8' },
      { rfilename: 'dict/pos_dict/prob_emit.utf8' },
      { rfilename: 'dict/pos_dict/prob_start.utf8' },
      { rfilename: 'dict/pos_dict/prob_trans.utf8' },
      { rfilename: 'dict/stop_words.utf8' },
      { rfilename: 'dict/user.dict.utf8' },
    ];
    return files;
  }

  // ---- 内部: 单文件下载 ----

  private static needsChunked_(fileSize: number | undefined): boolean {
    if (!fileSize || fileSize <= 0) return true;
    return fileSize > CHUNK_SIZE;
  }

  private static async downloadFile_(
    url: string,
    savePath: string,
    maxRetries: number,
    fallbackUrl: string,
    chunked: boolean,
  ): Promise<void> {
    try {
      if (chunked) {
        await TtsModelManager.chunkedDownload_(url, savePath);
      } else {
        await TtsModelManager.fullDownload_(url, savePath, maxRetries);
      }
    } catch (e) {
      if (fallbackUrl && fallbackUrl !== url) {
        console.info('[TtsModel] trying fallback: ' + fallbackUrl);
        if (chunked) {
          await TtsModelManager.chunkedDownload_(fallbackUrl, savePath);
        } else {
          await TtsModelManager.fullDownload_(fallbackUrl, savePath, maxRetries);
        }
      } else {
        throw new Error('下载失败: ' + (e as Error).message);
      }
    }
  }

  private static async fullDownload_(
    url: string,
    savePath: string,
    maxRetries: number,
  ): Promise<void> {
    for (let attempt = 0; attempt < maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          console.info('[TtsModel] retry ' + (attempt + 1) + ' for ' + url);
        }
        const session = rcp.createSession();
        const req = new rcp.Request(url, 'GET' as rcp.HttpMethod);
        const resp = await session.fetch(req);

        if (resp.statusCode !== 200) {
          throw new Error('HTTP ' + resp.statusCode);
        }
        if (!resp.body) {
          throw new Error('响应体为空');
        }

        const file = await fs.open(savePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          await fs.write(file.fd, resp.body as ArrayBuffer);
        } finally {
          await fs.close(file);
        }
        return;
      } catch (e) {
        console.warn('[TtsModel] download attempt ' + (attempt + 1) + ' failed: ' + (e as Error).message);
        try { await fs.unlink(savePath); } catch (_) { /* ignore */ }
        if (attempt === maxRetries - 1) {
          throw new Error('下载失败（已重试 ' + maxRetries + ' 次）: ' + (e as Error).message);
        }
      }
    }
  }

  private static async chunkedDownload_(url: string, savePath: string): Promise<void> {
    let offset = 0;
    let chunkIndex = 0;

    let file: fs.File | null = null;
    try {
      file = await fs.open(savePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    } catch (err) {
      throw new Error(`初始化下载文件失败: ${savePath}: ${(err as Error).message}`);
    } finally {
      if (file) {
        try {
          await fs.close(file);
        } catch (err) {
          console.warn('[TtsModel] close init file failed:', (err as Error).message);
        }
      }
    }

    while (true) {
      const start = offset;
      const end = offset + CHUNK_SIZE - 1;
      const rangeHeader = `bytes=${start}-${end}`;

      console.info('[TtsModel] chunk ' + chunkIndex + ': ' + rangeHeader);

      for (let retry = 0; retry < 3; retry++) {
        try {
          if (retry > 0) {
            console.info('[TtsModel] chunk retry ' + (retry + 1));
          }

          let session: rcp.Session | null = null;
          let resp: rcp.Response;
          try {
            session = rcp.createSession();
            const req = new rcp.Request(url, 'GET' as rcp.HttpMethod, {
              'Range': rangeHeader,
            } as rcp.RequestHeaders, '');
            resp = await session.fetch(req);
          } catch (err) {
            throw new Error('下载模型分片失败: ' + (err as Error).message);
          } finally {
            if (session) {
              try {
                session.close();
              } catch (err) {
                console.warn('[TtsModel] close chunk session failed:', (err as Error).message);
              }
            }
          }

          if (resp.statusCode === 416) {
            console.info('[TtsModel] HTTP 416: download complete, ' + offset + ' bytes');
            return;
          }

          if (resp.statusCode !== 206 && resp.statusCode !== 200) {
            throw new Error('HTTP ' + resp.statusCode);
          }

          if (!resp.body || (resp.body as ArrayBuffer).byteLength === 0) {
            console.info('[TtsModel] empty response: download complete');
            return;
          }

          file = null;
          try {
            file = await fs.open(savePath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
            await fs.write(file.fd, resp.body as ArrayBuffer);
          } catch (err) {
            throw new Error(`写入模型分片失败: ${savePath}: ${(err as Error).message}`);
          } finally {
            if (file) {
              try {
                await fs.close(file);
              } catch (err) {
                console.warn('[TtsModel] close chunk file failed:', (err as Error).message);
              }
            }
          }

          const receivedSize = (resp.body as ArrayBuffer).byteLength;
          offset += receivedSize;
          chunkIndex++;

          if (receivedSize < CHUNK_SIZE && resp.statusCode === 206) {
            console.info('[TtsModel] partial chunk: download complete, ' + offset + ' bytes');
            return;
          }
          break;
        } catch (e) {
          console.warn('[TtsModel] chunk ' + chunkIndex + ' attempt ' + (retry + 1) + ' failed: ' + (e as Error).message);
          if (retry === 2) {
            throw new Error('分块下载失败（chunk ' + chunkIndex + '）: ' + (e as Error).message);
          }
        }
      }
    }
  }

  // ---- 内部: 目录 ----

  private static async ensureDir_(dirPath: string): Promise<void> {
    try {
      await fs.mkdir(dirPath, true);
    } catch (e) {
      const msg = (e as Error).message || '';
      if (!msg.includes('exist') && !msg.includes('Exist')) {
        throw new Error('创建目录失败: ' + msg);
      }
    }
  }

  private static async deleteDir_(dirPath: string): Promise<void> {
    try {
      const files = await fs.listFile(dirPath);
      for (const file of files) {
        const fullPath = `${dirPath}/${file}`;
        try {
          const stat = await fs.stat(fullPath);
          if (stat.isDirectory()) {
            await TtsModelManager.deleteDir_(fullPath);
          } else {
            await fs.unlink(fullPath);
          }
        } catch (e) {
          console.warn('[TtsModel] delete failed: ' + fullPath + ' ' + (e as Error).message);
        }
      }
      await fs.rmdir(dirPath);
    } catch (_) { /* 目录不存在 */ }
  }
}
