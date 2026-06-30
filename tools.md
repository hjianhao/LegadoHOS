# 开发工具速查

## 抓取应用日志 (hilog)

```bash
export PATH="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"

# 抓取 info 级别日志，grep 过滤关键词
hdc -t 127.0.0.1:5555 shell "hilog -L I -n 200 2>/dev/null" 2>&1 | grep '\[SrcEx\]\|\[Explore\]\|\[BookCover\]\|\[NetUtil\]\|\[RCP\]\|Error' | tail -60

# 抓取 error 级别日志
hdc -t 127.0.0.1:5555 shell "hilog -L E -n 50 2>/dev/null" 2>&1 | grep -i 'legado\|JSAPP\|FATAL\|crash' | tail -30

# 查看崩溃日志 (faultlog)
hdc -t 127.0.0.1:5555 shell "ls -t /data/log/faultlog/faultlogger/ | grep legado | head -5"

# 拉取崩溃日志到本地
hdc -t 127.0.0.1:5555 file recv /data/log/faultlog/faultlogger/<文件名> /tmp/crash.log
```

**注意**: hilog 超时设为 3-5 秒，否则会卡住。| 管道在本地 grep 避免 hilog 管道阻塞。

## 构建与部署

```bash
source /Users/hjianhao/Code/ai/LegadoHOS/scripts/env.sh 2>/dev/null || \\
  export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH" && \\
  export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" && \\
  export NODE_HOME="/Applications/DevEco-Studio.app/Contents/tools/node"

cd /Users/hjianhao/Code/ai/LegadoHOS && bash scripts/build.sh debug

# 部署
export PATH="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains:$PATH"
hdc -t 127.0.0.1:5555 install -r entry/build/default/outputs/default/entry-default-signed.hap
hdc -t 127.0.0.1:5555 shell aa start -a MainAbility -b io.legado.hos
```
