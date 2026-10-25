// Dolby Vision fixtures with real RPUs (design section 7.8), built against Homebrew's FFmpeg as a
// generator only (fixtures.sh compiles it into build/fixtures/.src; Reel never links it).
//
// Decodes the video of a ramp file, attaches Dolby Vision metadata (AV_FRAME_DATA_DOVI_METADATA)
// to every frame and re-encodes with libx265 -dolbyvision 1, which writes an RPU NAL (type 62)
// per access unit; the MP4 muxer writes the configuration record (dvvC for profile 8, dvcC for 5).
//
//   make-dovi-rpu <in> <out.mp4> <profile: 81 | 84 | 5> <x265-params>
//
// 81 and 84: an identity reshaping (the base layer is the picture), PQ or HLG base, L1, L5 and L6.
// 5: profile 5 signalling (full range base, colour tags unspecified) over the same pixels; a
// real profile 5 base is IPTPQc2, so the picture is not meant to be correct, only the signalling.
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/opt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(const char *what, int code) {
    char text[128];
    av_strerror(code, text, sizeof(text));
    fprintf(stderr, "make-dovi-rpu: %s: %s\n", what, text);
    return 1;
}

static AVDOVIMetadata *make_metadata(int profile, int first, size_t *size) {
    AVDOVIMetadata *meta = av_dovi_metadata_alloc(size);
    if (!meta) return NULL;
    AVDOVIRpuDataHeader *h = av_dovi_get_header(meta);
    h->rpu_type = 2;
    h->rpu_format = 18;
    h->vdr_rpu_profile = profile == 5 ? 0 : 1;
    h->vdr_rpu_level = 0;
    h->chroma_resampling_explicit_filter_flag = 0;
    h->coef_data_type = 0;
    h->coef_log2_denom = 23;
    h->vdr_rpu_normalized_idc = 1;
    h->bl_video_full_range_flag = profile == 5;
    h->bl_bit_depth = 10;
    h->el_bit_depth = 10;
    h->vdr_bit_depth = 12;
    h->spatial_resampling_filter_flag = 0;
    h->el_spatial_resampling_filter_flag = 0;
    h->disable_residual_flag = 1;

    AVDOVIDataMapping *m = av_dovi_get_mapping(meta);
    m->vdr_rpu_id = 0;
    m->mapping_color_space = 0;
    m->mapping_chroma_format_idc = 0;
    m->nlq_method_idc = AV_DOVI_NLQ_NONE;
    m->num_x_partitions = 1;
    m->num_y_partitions = 1;
    for (int c = 0; c < 3; c++) {
        AVDOVIReshapingCurve *curve = &m->curves[c];
        curve->num_pivots = 2;
        curve->pivots[0] = 0;
        curve->pivots[1] = 1023;
        curve->mapping_idc[0] = AV_DOVI_MAPPING_POLYNOMIAL;
        curve->poly_order[0] = 1;
        curve->poly_coef[0][0] = 0;
        curve->poly_coef[0][1] = 1 << 23;
        curve->poly_coef[0][2] = 0;
    }

    // Level 0 display management values as dovi_tool and FFmpeg's defaults write them (BT.2020).
    static const int ycc[9] = { 9575, 0, 14742, 9575, 1754, 4383, 9575, 17372, 0 };
    static const int lms[9] = { 5845, 9702, 837, 2568, 12256, 1561, 0, 679, 15705 };
    AVDOVIColorMetadata *color = av_dovi_get_color(meta);
    color->dm_metadata_id = 0;
    color->scene_refresh_flag = first;
    for (int i = 0; i < 9; i++) {
        color->ycc_to_rgb_matrix[i] = (AVRational) { ycc[i], 8192 };
        color->rgb_to_lms_matrix[i] = (AVRational) { lms[i], 16384 };
    }
    color->ycc_to_rgb_offset[0] = (AVRational) { 1, 4 };
    color->ycc_to_rgb_offset[1] = (AVRational) { 2, 1 };
    color->ycc_to_rgb_offset[2] = (AVRational) { 2, 1 };
    color->signal_eotf = 39322;
    color->signal_eotf_param0 = 15867;
    color->signal_eotf_param1 = 228;
    color->signal_eotf_param2 = 1383604;
    color->signal_bit_depth = 14;
    color->signal_color_space = 0;
    color->signal_chroma_format = 0;
    color->signal_full_range_flag = 1;
    color->source_min_pq = 62;
    color->source_max_pq = 3079; // 1000 nits
    color->source_diagonal = 42;

    meta->num_ext_blocks = 3;
    AVDOVIDmData *l1 = av_dovi_get_ext(meta, 0);
    l1->level = 1;
    l1->l1 = (AVDOVIDmLevel1) { .min_pq = 0, .max_pq = 3079, .avg_pq = 1600 };
    AVDOVIDmData *l5 = av_dovi_get_ext(meta, 1);
    l5->level = 5;
    l5->l5 = (AVDOVIDmLevel5) { 0, 0, 0, 0 };
    AVDOVIDmData *l6 = av_dovi_get_ext(meta, 2);
    l6->level = 6;
    l6->l6 = (AVDOVIDmLevel6) { .max_luminance = 1000, .min_luminance = 1, .max_cll = 1000, .max_fall = 400 };
    return meta;
}

static int drain(AVCodecContext *enc, AVFormatContext *out, AVStream *st, AVPacket *pkt) {
    int ret;
    while ((ret = avcodec_receive_packet(enc, pkt)) >= 0) {
        av_packet_rescale_ts(pkt, enc->time_base, st->time_base);
        pkt->stream_index = st->index;
        if ((ret = av_interleaved_write_frame(out, pkt)) < 0) return ret;
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: make-dovi-rpu <in> <out.mp4> <81|84|5> <x265-params>\n");
        return 2;
    }
    const char *in_path = argv[1], *out_path = argv[2], *params = argv[4];
    int mode = atoi(argv[3]);
    int profile = mode == 5 ? 5 : 8;
    int ret;
    av_log_set_level(AV_LOG_ERROR);

    AVFormatContext *in = NULL;
    if ((ret = avformat_open_input(&in, in_path, NULL, NULL)) < 0) return fail("open input", ret);
    if ((ret = avformat_find_stream_info(in, NULL)) < 0) return fail("stream info", ret);
    int vi = av_find_best_stream(in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vi < 0) return fail("no video", vi);
    AVStream *ist = in->streams[vi];
    const AVCodec *dcodec = avcodec_find_decoder(ist->codecpar->codec_id);
    AVCodecContext *dec = avcodec_alloc_context3(dcodec);
    avcodec_parameters_to_context(dec, ist->codecpar);
    if ((ret = avcodec_open2(dec, dcodec, NULL)) < 0) return fail("open decoder", ret);

    const AVCodec *ecodec = avcodec_find_encoder_by_name("libx265");
    if (!ecodec) { fprintf(stderr, "make-dovi-rpu: no libx265\n"); return 1; }
    AVCodecContext *enc = avcodec_alloc_context3(ecodec);
    enc->width = dec->width;
    enc->height = dec->height;
    enc->pix_fmt = AV_PIX_FMT_YUV420P10;
    AVRational rate = av_guess_frame_rate(in, ist, NULL);
    enc->framerate = rate;
    enc->time_base = av_inv_q(rate);
    enc->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
    if (profile == 5) {
        enc->color_primaries = AVCOL_PRI_UNSPECIFIED;
        enc->color_trc = AVCOL_TRC_UNSPECIFIED;
        enc->colorspace = AVCOL_SPC_UNSPECIFIED;
        enc->color_range = AVCOL_RANGE_JPEG;
    } else {
        enc->color_primaries = AVCOL_PRI_BT2020;
        enc->color_trc = mode == 84 ? AVCOL_TRC_ARIB_STD_B67 : AVCOL_TRC_SMPTE2084;
        enc->colorspace = AVCOL_SPC_BT2020_NCL;
        enc->color_range = AVCOL_RANGE_MPEG;
    }
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "dolbyvision", "1", 0);
    av_dict_set(&opts, "preset", "ultrafast", 0);
    av_dict_set(&opts, "x265-params", params, 0);
    // The configuration record goes in the sample entry (hvcC), as Apple's tools write it.
    enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if ((ret = avcodec_open2(enc, ecodec, &opts)) < 0) return fail("open libx265", ret);
    av_dict_free(&opts);

    AVFormatContext *out = NULL;
    if ((ret = avformat_alloc_output_context2(&out, NULL, NULL, out_path)) < 0) return fail("output", ret);
    out->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
    AVStream *ost = avformat_new_stream(out, NULL);
    if ((ret = avcodec_parameters_from_context(ost->codecpar, enc)) < 0) return fail("codec parameters", ret);
    ost->time_base = enc->time_base;
    // hvc1 for profile 8 (Apple's HEVC entry), dvh1 for profile 5 (no compatible base).
    ost->codecpar->codec_tag = profile == 5 ? MKTAG('d', 'v', 'h', '1') : MKTAG('h', 'v', 'c', '1');
    if ((ret = avio_open(&out->pb, out_path, AVIO_FLAG_WRITE)) < 0) return fail("open output", ret);
    if ((ret = avformat_write_header(out, NULL)) < 0) return fail("write header", ret);

    AVPacket *pkt = av_packet_alloc(), *epkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int64_t index = 0;
    for (int flushing = 0; ; ) {
        if (!flushing) {
            ret = av_read_frame(in, pkt);
            if (ret < 0) { flushing = 1; avcodec_send_packet(dec, NULL); }
            else if (pkt->stream_index != vi) { av_packet_unref(pkt); continue; }
            else { avcodec_send_packet(dec, pkt); av_packet_unref(pkt); }
        }
        while ((ret = avcodec_receive_frame(dec, frame)) >= 0) {
            size_t size;
            AVDOVIMetadata *meta = make_metadata(profile, index == 0, &size);
            if (!meta) return fail("metadata", AVERROR(ENOMEM));
            AVBufferRef *buf = av_buffer_create((uint8_t *) meta, size, NULL, NULL, 0);
            if (!buf || !av_frame_new_side_data_from_buf(frame, AV_FRAME_DATA_DOVI_METADATA, buf)) return fail("side data", AVERROR(ENOMEM));
            frame->pts = index++;
            frame->pict_type = AV_PICTURE_TYPE_NONE;
            frame->color_primaries = enc->color_primaries;
            frame->color_trc = enc->color_trc;
            frame->colorspace = enc->colorspace;
            frame->color_range = enc->color_range;
            if ((ret = avcodec_send_frame(enc, frame)) < 0) return fail("encode", ret);
            av_frame_unref(frame);
            if ((ret = drain(enc, out, ost, epkt)) < 0) return fail("write", ret);
        }
        if (flushing && ret == AVERROR_EOF) break;
    }
    avcodec_send_frame(enc, NULL);
    if ((ret = drain(enc, out, ost, epkt)) < 0) return fail("write", ret);
    if ((ret = av_write_trailer(out)) < 0) return fail("trailer", ret);
    avio_closep(&out->pb);
    fprintf(stderr, "make-dovi-rpu: %s, %lld frames, profile %d\n", out_path, (long long) index, mode);
    avformat_free_context(out);
    avformat_close_input(&in);
    return 0;
}
