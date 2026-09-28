import Testing

enum ScriptPieces {
  static let repeatTail = "  } while true\n"
  static let exitBeforeDone = "while :; do\n  sleep 1\n  exit 0\n"
  static let breakAfterInnerLoop = "while :; do\n  for f in *; do\n    echo $f\n  done\n  break\ndone\n"
  static let tabIndentedBreak = "while True:\n\tbreak\n"
}
