/**
 * 播放列表管理器
 * 管理有声书的章节播放顺序、循环模式
 */
import { AudioTrack } from './AudioPlayer';

export enum PlayMode {
  SEQUENTIAL = 0,    // 顺序播放
  REPEAT_ONE = 1,    // 单曲循环
  REPEAT_ALL = 2,    // 列表循环
  SHUFFLE = 3,       // 随机播放
}

export class PlaylistManager {
  private tracks_: AudioTrack[] = [];
  private currentIndex_: number = 0;
  private playMode_: PlayMode = PlayMode.SEQUENTIAL;
  private shuffledOrder_: number[] = [];

  get tracks(): AudioTrack[] { return this.tracks_; }
  get currentIndex(): number { return this.currentIndex_; }
  get currentTrack(): AudioTrack | null {
    return this.tracks_[this.currentIndex_] || null;
  }
  get playMode(): PlayMode { return this.playMode_; }
  get total(): number { return this.tracks_.length; }

  setPlaylist(tracks: AudioTrack[], startIndex: number = 0): void {
    this.tracks_ = tracks;
    this.currentIndex_ = Math.min(startIndex, tracks.length - 1);
    this.genShuffleOrder();
  }

  addTrack(track: AudioTrack): void {
    this.tracks_.push(track);
    this.genShuffleOrder();
  }

  removeTrack(index: number): void {
    if (index >= 0 && index < this.tracks_.length) {
      this.tracks_.splice(index, 1);
      if (this.currentIndex_ >= this.tracks_.length) {
        this.currentIndex_ = Math.max(0, this.tracks_.length - 1);
      }
      this.genShuffleOrder();
    }
  }

  setPlayMode(mode: PlayMode): void {
    this.playMode_ = mode;
    this.genShuffleOrder();
  }

  /**
   * 下一首
   */
  next(): AudioTrack | null {
    switch (this.playMode_) {
      case PlayMode.REPEAT_ONE:
        return this.currentTrack;
      case PlayMode.SEQUENTIAL:
        if (this.currentIndex_ < this.tracks_.length - 1) {
          this.currentIndex_++;
          return this.currentTrack;
        }
        return null;
      case PlayMode.REPEAT_ALL:
        this.currentIndex_ = (this.currentIndex_ + 1) % this.tracks_.length;
        return this.currentTrack;
      case PlayMode.SHUFFLE:
        this.currentIndex_ = this.getNextShuffled();
        return this.currentTrack;
    }
  }

  /**
   * 上一首
   */
  prev(): AudioTrack | null {
    if (this.currentIndex_ > 0) {
      this.currentIndex_--;
      return this.currentTrack;
    }
    return null;
  }

  goTo(index: number): AudioTrack | null {
    if (index >= 0 && index < this.tracks_.length) {
      this.currentIndex_ = index;
      return this.currentTrack;
    }
    return null;
  }

  clear(): void {
    this.tracks_ = [];
    this.currentIndex_ = 0;
    this.shuffledOrder_ = [];
  }

  private genShuffleOrder(): void {
    this.shuffledOrder_ = [];
    for (let i = 0; i < this.tracks_.length; i++) {
      this.shuffledOrder_.push(i);
    }
    // Fisher-Yates shuffle
    for (let i = this.shuffledOrder_.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [this.shuffledOrder_[i], this.shuffledOrder_[j]] =
        [this.shuffledOrder_[j], this.shuffledOrder_[i]];
    }
  }

  private getNextShuffled(): number {
    const currentPos = this.shuffledOrder_.indexOf(this.currentIndex_);
    const nextPos = (currentPos + 1) % this.shuffledOrder_.length;
    return this.shuffledOrder_[nextPos];
  }
}
