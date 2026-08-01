/* SwiftPM C target 需要至少一个源文件；ABI 实现在 RustCore 静态库
 * （scripts/build-rust-core.sh 产物 RustCore/dist/librustcore.a）。
 * 本文件仅锚定头文件，保证头文件参与编译校验。 */
#include "rustcore.h"
