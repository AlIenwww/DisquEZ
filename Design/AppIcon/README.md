# DisquEZ 图标

采用用户选定的原版石墨黑与黄绿色折叠 D。

- 原生可编辑工程：`../../DisquEZ/DisquEZ.icon`，使用 Apple Icon Composer 打开。
- `Sources` 保存矢量路径与生成透明渐变图层的原生绘图源文件。
- 图标分为折面、D 主体、石墨背景纹理，背景颜色独立保存在原生工程中。
- D 主体和折面统一向右移动 16/1254 个画布宽度（约 1.28%，相当于 1024 画布上的 13.1 px），用于视觉居中补偿，垂直位置沿用原稿。
- 原稿亮色区域的面积重心约为 x=605，而画布中心为 x=627；外框中心约为 x=636.5。几何边距与视觉重心并不相同，因此采用小幅光学校正。
- 在 Icon Composer 中，前景组及折面排在图层列表上方。为保留原稿柔和折面，关闭了前景图层的额外玻璃厚边。
- D 的渐变图层使用带透明通道的 PNG；可编辑 SVG 和原生绘图源文件一并保留。

预览由 Apple Icon Composer 随附的 ictool 渲染。

重新生成 D 的渐变图层：

```sh
swift -module-cache-path /tmp/disquez-swift-cache Design/AppIcon/Sources/RenderLayers.swift "$PWD/DisquEZ/DisquEZ.icon/Assets"
```

Xcode 的 Debug 和 Release 配置都将这份分层文件用作 DisquEZ 的主图标。
