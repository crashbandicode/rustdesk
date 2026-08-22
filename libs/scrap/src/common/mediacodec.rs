use hbb_common::{anyhow::Error, bail, log, ResultType};
use ndk::media::media_codec::{MediaCodec, MediaCodecDirection, MediaFormat};
use std::ops::Deref;
use std::{
    io::Write,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use crate::{CodecFormat, I420ToABGR, I420ToARGB, ImageFormat, ImageRgb, NV12ToABGR, NV12ToARGB};

/// MediaCodec mime type name
const H264_MIME_TYPE: &str = "video/avc";
const H265_MIME_TYPE: &str = "video/hevc";
// const VP8_MIME_TYPE: &str = "video/x-vnd.on2.vp8";
// const VP9_MIME_TYPE: &str = "video/x-vnd.on2.vp9";

// TODO MediaCodecEncoder

pub static H264_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);
pub static H265_DECODER_SUPPORT: AtomicBool = AtomicBool::new(false);

pub struct MediaCodecDecoder {
    decoder: MediaCodec,
    name: String,
}

pub struct MediaCodecDecoders {
    pub h264: Option<MediaCodecDecoder>,
    pub h265: Option<MediaCodecDecoder>,
}

impl Deref for MediaCodecDecoder {
    type Target = MediaCodec;

    fn deref(&self) -> &Self::Target {
        &self.decoder
    }
}

impl MediaCodecDecoder {
    pub fn new_decoders() -> MediaCodecDecoders {
        MediaCodecDecoders {
            h264: create_media_codec(H264_MIME_TYPE, MediaCodecDirection::Decoder),
            h265: create_media_codec(H265_MIME_TYPE, MediaCodecDirection::Decoder),
        }
    }

    pub fn new(format: CodecFormat) -> Option<MediaCodecDecoder> {
        match format {
            CodecFormat::H264 => create_media_codec(H264_MIME_TYPE, MediaCodecDirection::Decoder),
            CodecFormat::H265 => create_media_codec(H265_MIME_TYPE, MediaCodecDirection::Decoder),
            _ => {
                log::error!("Unsupported codec format: {:?}", format);
                None
            }
        }
    }

    // rgb [in/out] fmt and stride must be set in ImageRgb
    pub fn decode(&mut self, data: &[u8], rgb: &mut ImageRgb) -> ResultType<bool> {
        match self.dequeue_input_buffer(Duration::from_millis(10))? {
            Some(mut input_buffer) => {
                let mut buf = input_buffer.buffer_mut();
                if data.len() > buf.len() {
                    log::error!("Failed to decode, the input data size is bigger than input buf");
                    bail!("The input data size is bigger than input buf");
                }
                buf.write_all(&data)?;
                self.queue_input_buffer(input_buffer, 0, data.len(), 0, 0)?;
            }
            None => {
                log::debug!("Failed to dequeue_input_buffer: No available input_buffer");
            }
        };

        return match self.dequeue_output_buffer(Duration::from_millis(100))? {
            Some(output_buffer) => {
                let res_format = self.output_format();
                let w = res_format
                    .i32("width")
                    .ok_or(Error::msg("Failed to dequeue_output_buffer, width is None"))?
                    as usize;
                let h = res_format.i32("height").ok_or(Error::msg(
                    "Failed to dequeue_output_buffer, height is None",
                ))? as usize;
                let stride = res_format.i32("stride").ok_or(Error::msg(
                    "Failed to dequeue_output_buffer, stride is None",
                ))? as usize;
                let slice_height = res_format
                    .i32("slice-height")
                    .filter(|value| *value > 0)
                    .map(|value| value as usize)
                    .unwrap_or(h);
                let color_format = res_format.i32("color-format").unwrap_or(19);
                let buf = output_buffer.buffer();
                let bps = 4;
                rgb.w = w;
                rgb.h = h;
                let dst_align = rgb.align();
                let bytes_per_row = (w * bps + dst_align - 1) & !(dst_align - 1);
                rgb.raw.resize(h * bytes_per_row, 0);
                let y_ptr = buf.as_ptr();
                let y_size = stride * slice_height;
                if buf.len() < y_size {
                    bail!("MediaCodec output is smaller than its Y plane");
                }
                unsafe {
                    match color_format {
                        19 => {
                            let chroma_stride = (stride + 1) / 2;
                            let chroma_height = (slice_height + 1) / 2;
                            let u_size = chroma_stride * chroma_height;
                            if buf.len() < y_size + u_size * 2 {
                                bail!("MediaCodec planar output is truncated");
                            }
                            let u_ptr = buf[y_size..].as_ptr();
                            let v_ptr = buf[y_size + u_size..].as_ptr();
                            let convert = match rgb.fmt() {
                                ImageFormat::ARGB => I420ToARGB,
                                ImageFormat::ABGR => I420ToABGR,
                                _ => bail!("Unsupported image format"),
                            };
                            convert(
                                y_ptr,
                                stride as _,
                                u_ptr,
                                chroma_stride as _,
                                v_ptr,
                                chroma_stride as _,
                                rgb.raw.as_mut_ptr(),
                                bytes_per_row as _,
                                w as _,
                                h as _,
                            );
                        }
                        21 => {
                            let uv_stride = stride;
                            if buf.len() < y_size + uv_stride * ((slice_height + 1) / 2) {
                                bail!("MediaCodec semi-planar output is truncated");
                            }
                            let uv_ptr = buf[y_size..].as_ptr();
                            let convert = match rgb.fmt() {
                                ImageFormat::ARGB => NV12ToARGB,
                                ImageFormat::ABGR => NV12ToABGR,
                                _ => bail!("Unsupported image format"),
                            };
                            convert(
                                y_ptr,
                                stride as _,
                                uv_ptr,
                                uv_stride as _,
                                rgb.raw.as_mut_ptr(),
                                bytes_per_row as _,
                                w as _,
                                h as _,
                            );
                        }
                        _ => bail!("Unsupported MediaCodec color format: {color_format}"),
                    }
                }
                self.release_output_buffer(output_buffer, false)?;
                Ok(true)
            }
            None => {
                log::debug!("Failed to dequeue_output: No available dequeue_output");
                Ok(false)
            }
        };
    }
}

fn create_media_codec(name: &str, direction: MediaCodecDirection) -> Option<MediaCodecDecoder> {
    let codec = MediaCodec::from_decoder_type(name)?;
    let media_format = MediaFormat::new();
    media_format.set_str("mime", name);
    media_format.set_i32("width", 0);
    media_format.set_i32("height", 0);
    media_format.set_i32("color-format", 19); // COLOR_FormatYUV420Planar
    if let Err(e) = codec.configure(&media_format, None, direction) {
        log::error!("Failed to init decoder: {:?}", e);
        return None;
    };
    log::error!("decoder init success");
    if let Err(e) = codec.start() {
        log::error!("Failed to start decoder: {:?}", e);
        return None;
    };
    log::debug!("Init decoder succeeded!: {:?}", name);
    return Some(MediaCodecDecoder {
        decoder: codec,
        name: name.to_owned(),
    });
}

pub fn check_mediacodec() {
    std::thread::spawn(move || {
        // check decoders
        let decoders = MediaCodecDecoder::new_decoders();
        H264_DECODER_SUPPORT.swap(decoders.h264.is_some(), Ordering::SeqCst);
        H265_DECODER_SUPPORT.swap(decoders.h265.is_some(), Ordering::SeqCst);
        decoders.h264.map(|d| d.stop());
        decoders.h265.map(|d| d.stop());
        // TODO encoders
    });
}
