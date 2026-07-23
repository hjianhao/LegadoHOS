/**
 * 备份/恢复互斥锁（对齐 Android BackupRestoreLock）
 * 用 Promise 链串行化并发任务，避免同时写库/写 zip。
 */
export class BackupRestoreLock {
  private static chain: Promise<void> = Promise.resolve();

  static async withLock<T>(action: () => Promise<T>): Promise<T> {
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const prev = BackupRestoreLock.chain;
    BackupRestoreLock.chain = prev.then(() => gate).catch(() => gate);
    await prev.catch(() => {});
    try {
      return await action();
    } finally {
      release();
    }
  }
}
