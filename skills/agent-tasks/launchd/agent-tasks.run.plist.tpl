<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>agent-tasks.run</string>
  <key>ProgramArguments</key>
  <array>
    <string>__TASK_BIN__</string>
    <string>run</string>
    <string>--once</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>__PATH__</string>
    <key>AGENT_TASKS_HOME</key>
    <string>__STORE__</string>
  </dict>
  <key>StandardOutPath</key>
  <string>__LOG__</string>
  <key>StandardErrorPath</key>
  <string>__LOG__</string>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
