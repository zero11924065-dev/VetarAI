// checkpoint-065：用 AppKit 合成标准 macOS 图标（白圆角底 + 居中留边 Logo）
// 运行：osascript -l JavaScript build/make_icon.js（目录需先用 shell 建好）
ObjC.import('AppKit');
ObjC.import('Foundation');

var LOGO = '/Users/vetar/Desktop/beta/subagent/renderer/src/assets/logo.png';
var OUT = '/Users/vetar/Desktop/beta/subagent/build/icon2.iconset/';

var map = {
  'icon_16x16.png':16, 'icon_16x16@2x.png':32, 'icon_32x32.png':32, 'icon_32x32@2x.png':64,
  'icon_128x128.png':128, 'icon_128x128@2x.png':256, 'icon_256x256.png':256, 'icon_256x256@2x.png':512,
  'icon_512x512.png':512, 'icon_512x512@2x.png':1024
};

var logo = $.NSImage.alloc.initWithContentsOfFile(LOGO);
var props = $.NSDictionary.dictionary;
var done = 0;
for (var name in map) {
  var size = map[name];
  var img = $.NSImage.alloc.initWithSize({width:size, height:size});
  img.lockFocus;
  // 白圆角底（macOS 标准圆角比例 ~22%）
  var r = size * 0.22;
  var bg = $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius({x:0, y:0, width:size, height:size}, r, r);
  $.NSColor.whiteColor.set;
  bg.fill;
  // Logo 居中，四周留 14% 边距（视觉与其他应用对齐）
  var pad = Math.round(size * 0.14);
  logo.drawInRectFromRectOperationFraction(
    {x:pad, y:pad, width:size - 2*pad, height:size - 2*pad},
    $.NSZeroRect,
    $.NSCompositingOperationSourceOver,
    1.0
  );
  img.unlockFocus;
  var tiff = img.TIFFRepresentation;
  var rep = $.NSBitmapImageRep.imageRepWithData(tiff);
  var png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, props);
  png.writeToFileAtomically(OUT + name, true);
  done++;
}
'generated ' + done + ' icons';
