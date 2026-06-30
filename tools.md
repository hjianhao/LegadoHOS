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

## 抓取 hilog 方法

### 1. 获取应用 PID
```bash
hdc -t 127.0.0.1:5555 shell ps -A | grep legado | awk '{print $2}'
```

### 2. 抓取应用的 hilog（仅错误级别）
```bash
hdc -t 127.0.0.1:5555 hilog -P <PID> -L E
```

### 3. 抓取全部级别并过滤应用关键词
```bash
hdc -t 127.0.0.1:5555 hilog -P <PID> | grep -E "ReadPage|loadContent|SrcEx|error|ERROR|getToc|chapter|BookInfo"
```

### 4. 清除旧日志后抓取新日志
```bash
hdc -t 127.0.0.1:5555 shell hilog -r  # 清除日志缓冲
# 操作应用触发问题
hdc -t 127.0.0.1:5555 hilog -P <PID> | grep -i "legado\|ReadPage\|loadContent\|fetch\|getToc\|error" | head -50
```

### 注意事项
- `console.error()` 输出级别为 ERROR，`console.info()` 输出为 INFO
- 优先在关键路径使用 `console.error()` 以确保日志级别可见
- hilog -r 清缓冲后需要立即操作应用，稍等几秒再抓取
