#!/bin/bash
# Claude Code hook - 質問・承認待ちの時に通知音を鳴らす（完了音のGlassとは別の音）
afplay /System/Library/Sounds/Funk.aiff >/dev/null 2>&1 &
exit 0
