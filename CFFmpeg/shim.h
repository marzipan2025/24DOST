// ffmpeg 라이브러리(빌드는 Homebrew 의 것을 링크하고, Packaging/make_dmg.sh 가 앱의 Frameworks 로 옮겨 단다)
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
