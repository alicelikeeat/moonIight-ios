"""Inventory app-owned SwiftUI/UIKit control declarations; no runtime claims."""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
pattern = re.compile(r'\b(Button|NavigationLink|Menu|ToolbarItem|PhotosPicker|ColorPicker|Toggle|Slider|Stepper|TextField|SecureField|UIButton)\s*(?:\(|\{)|\.(onTapGesture|onSubmit|addTarget)\s*(?:\(|\{)')
rows = []
for path in sorted(root.glob('*.swift')):
    scope = ''
    lines = path.read_text().splitlines()
    for number, line in enumerate(lines, 1):
        declaration = re.search(r'\b(?:struct|class|enum|extension)\s+(\w+)', line)
        if declaration:
            scope = declaration[1]
        for match in pattern.finditer(line):
            kind = match[1] or match[2]
            snippet = ' '.join(lines[number - 1:number + 3]).strip()
            snippet = snippet.replace('|', '\\|').replace('`', "'")[:240]
            rows.append(f'| [{path.name}:{number}](../{path.name}#L{number}) | {scope} | {kind} | `{snippet}` | 已定位声明；运行验证见主审计表 |')
output = root / 'docs' / 'CONTROL_INVENTORY.md'
output.parent.mkdir(exist_ok=True)
output.write_text('# 控件声明清单\n\n由 `python3 scripts/audit_controls.py` 生成。覆盖根目录所有应用 Swift 源文件中的 SwiftUI 控件、UIKit UIButton、提交与点击入口；包括条件编译声明，系统或第三方控件内部不在源码控制范围内。此清单不等于逐个控件真机通过，预期行为、handler 和关键回归结果见 [按钮审计](BUTTON_AUDIT.md)。\n\n'
                  + f'共 {len(rows)} 个声明/入口。\n\n| 位置 | 所在类型 | 控件 | 声明及 handler 摘要 | 状态 |\n|---|---|---|---|---|\n'
                  + '\n'.join(rows) + '\n')
print(f'Inventoried {len(rows)} controls -> {output.relative_to(root)}')
