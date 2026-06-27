/**
 * @kit.SpeechKit - 项目内类型声明
 * 参考: https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/speech-textreader-api-V5
 */
declare module '@kit.SpeechKit' {
  export namespace TextReader {
    interface ReadInfo {
      id: string;
      title?: { text: string; isClickable?: boolean };
      author?: { text: string; isClickable?: boolean };
      date?: { text: string; isClickable?: boolean };
      bodyInfo: string;
    }
    interface ReaderParams {
      panelMode?: number;
      supportReadBackground?: boolean;
      isVoiceBrandVisible?: boolean;
      businessBrandInfo?: {
        panelName?: string;
        panelIcon?: Resource;
      };
    }
    function init(context: Context, params?: ReaderParams): Promise<void>;
    function start(readInfoList: ReadInfo[], selectedId?: string): Promise<void>;
    function loadMore(readInfos: ReadInfo[], isEnd: boolean): void;
    function stop(): Promise<void>;
    function pause(): Promise<void>;
    function resume(): Promise<void>;
    function showPanel(): void;
    function hidePanel(): void;
    function hideMinibar(): void;
    function on(event: string, callback: Function): void;
    function off(event: string, callback?: Function): void;
    function destroy(): Promise<void>;
    function getSpeed(): number;
    function setSpeed(speed: number): void;
    function setSpeechRate(rate: number): void;
  }

  export namespace textToSpeech {
    interface CreateEngineParams {
      language?: string;
      person?: number;
    }
    interface SpeakParams {
      utteranceId: string;
      extraParams?: { speed?: number; volume?: number; pitch?: number };
    }
    interface TtsEngine {
      speak(text: string, params: SpeakParams): Promise<void>;
      stop(): Promise<void>;
      pause(): Promise<void>;
      resume(): Promise<void>;
      release(): void;
      setParams(params: Record<string, Object>): void;
      on(event: string, callback: Function): void;
      off(event: string, callback?: Function): void;
    }
    function createEngine(params: CreateEngineParams): Promise<TtsEngine>;
  }
}
