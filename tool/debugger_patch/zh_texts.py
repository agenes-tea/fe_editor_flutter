#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Chinese menu strings for the SRR (FE8) debugger.

Character policy: every char must be encodable in cp932 (JIS glyph set),
so it can exist in the SRR JP character ROM. Use JIS-form codepoints:
値(U+5024) not 值, 状(U+72B6) not 狀, 単 not 单, etc. The Huffman tree is
extended with these codes at build time (glyph availability in-game is the
user's to verify; common kanji should be covered by the JP glyph ROM).
"""
import re

GLOBAL_MAP = {
    " Pickup": " 移動角色",
    "Pickup a unit and\\place them anywhere.": "拾起單位並\\移到任意格。",
    " Level up": " 升級",
    "Level up\\the unit.": "升級\\當前單位。",
    " Stats": " 屬性値",
    "Edit a unit's stats.": "編輯單位的\\能力數値。",
    " Misc": " 雜項屬性",
    "Edit unit's ID, class,\\bonuses, and more.": "編輯編號、職業、\\加成等。",
    " Items": " 道具",
    "Edit a unit's items.": "編輯單位的道具。",
    " State": " 人物状態",
    " WExp": " 武器経験",
    "Edit WExp\\for the unit.": "編輯單位\\的武器熟練度。",
    " Supports": " 支援",
    "Edit support levels\\for the unit.": "編輯單位\\的支援等級。",
    " Page": " 頁碼",
    "Swap pages in\\this debugger.": "切換頁面。",
    " Godmode off": " 無敵 關",
    "Make your units\\win every battle.": "我方必定\\勝利。",
    " Enemy Ctrl off": " 敵軍控制 關",
    "Control just players\\or control everyone.": "控制我方\\或全體。",
    " Edit Map": " 地圖編輯",
    "Edit tiles on the\\map with the tileset.": "用圖塊\\編輯地圖。",
    " Traps": " 陷穽",
    "Edit trap slots\\and trap data.": "編輯陷穽\\槽位與數據。",
    " Ch. State": " 章節状態",
    "Edit things about\\the chapter.": "金幣、天氣、回合、\\旗標等。",
    " Clear Ch.": " 清除章節",
    "Clear the current\\chapter.": "立即結束\\當前章節。",
    " Load units": " 載入單位",
    "Load units.\\Possibly useful.": "載入單位。\\實用。",
    " Boot title": " 開機:標題",
    " Supply": " 運輸隊",
    "Open the convoy\\to access items.": "打開運輸隊\\取用物品。",
    " List": " 物品清単",
    " Promote": " 轉職",
    "Promote the unit\\into an advanced\\class.": "轉職到\\上位職業。",
    " Arena": " 競技場",
    "Enter the arena\\and fight for glory.": "進入競技場\\決一勝負。",
    " Autoplay off": " 自動演出 關",
    " AI": " AI",
    "Edit unit's AI.": "編輯單位 AI。",
    " Gfx viewer": " 圖素檢視",
    " BGM": " 音樂",
    "Change the current\\music track.": "切換當前音樂。",
}

# label-aware: several descriptions share the same English source text
BLOCK_MAP = {
    "ListMenuDesc": "看全\\物品清単。",
    "AiControlRemainingUnitsDesc": "未行動單位\\自動演出。",
    "GfxViewerDesc": "檢視圖素與\\戰鬥動畫。",
    "SupportMenuDesc": "編輯單位\\的支援等級。",
}

def remap(installer_text):
    s = installer_text
    for en, zh in GLOBAL_MAP.items():
        s = s.replace('"%s"' % en, '"%s"' % zh)
    for label, zh in BLOCK_MAP.items():
        # label line followed (next non-empty line) by txt("...")
        pat = re.compile(r'^(%s:\s*\n\s*txt\()[^"]*(\)\s*;?\s*$)' % re.escape(label), re.M)
        s = pat.sub(lambda m: m.group(1) + '"%s"' % zh + m.group(2), s)
    return s

def zh_chars_used():
    chars = set()
    for zh in list(GLOBAL_MAP.values()) + list(BLOCK_MAP.values()):
        chars.update(set(zh))
    return chars
