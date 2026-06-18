/**
 * 朗读定时器
 * 支持: 定时关闭（15/30/45/60分钟/当前章节完）
 */
export enum TimerMode {
  OFF = 0,
  MIN_15 = 15,
  MIN_30 = 30,
  MIN_45 = 45,
  MIN_60 = 60,
  CHAPTER_END = -1,   // 当前章节结束
}

export type TimerCallback = () => void;

export class ReadTimer {
  private remaining_: number = 0;        // 剩余秒数
  private mode_: TimerMode = TimerMode.OFF;
  private active_: boolean = false;
  private intervalId_: number | null = null;
  private onTimeout_: TimerCallback | null = null;

  get remaining(): number { return this.remaining_; }
  get mode(): TimerMode { return this.mode_; }
  get active(): boolean { return this.active_; }
  get remainingFormatted(): string {
    const m = Math.floor(this.remaining_ / 60);
    const s = this.remaining_ % 60;
    return `${m}:${s.toString().padStart(2, '0')}`;
  }

  set onTimeout(cb: TimerCallback) { this.onTimeout_ = cb; }

  /**
   * 启动定时
   */
  start(mode: TimerMode): void {
    this.stop();
    this.mode_ = mode;

    if (mode === TimerMode.OFF) return;

    if (mode === TimerMode.CHAPTER_END) {
      // 章节结束时触发，不由计时器驱动
      this.active_ = true;
      return;
    }

    this.remaining_ = mode * 60; // 分钟→秒
    this.active_ = true;

    this.intervalId_ = setInterval(() => {
      this.remaining_--;
      if (this.remaining_ <= 0) {
        this.stop();
        this.onTimeout_?.();
      }
    }, 1000);
  }

  /**
   * 停止定时器
   */
  stop(): void {
    this.active_ = false;
    this.mode_ = TimerMode.OFF;
    this.remaining_ = 0;
    if (this.intervalId_ !== null) {
      clearInterval(this.intervalId_);
      this.intervalId_ = null;
    }
  }

  /**
   * 暂停计时
   */
  pause(): void {
    if (this.intervalId_ !== null) {
      clearInterval(this.intervalId_);
      this.intervalId_ = null;
    }
  }

  /**
   * 恢复计时
   */
  resume(): void {
    if (this.active_ && this.remaining_ > 0 && this.mode_ !== TimerMode.CHAPTER_END) {
      this.intervalId_ = setInterval(() => {
        this.remaining_--;
        if (this.remaining_ <= 0) {
          this.stop();
          this.onTimeout_?.();
        }
      }, 1000);
    }
  }

  /**
   * 标记章节结束（用于 CHAPTER_END 模式）
   */
  onChapterEnd(): void {
    if (this.active_ && this.mode_ === TimerMode.CHAPTER_END) {
      this.stop();
      this.onTimeout_?.();
    }
  }
}
