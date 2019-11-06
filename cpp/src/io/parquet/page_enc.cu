/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "parquet_gpu.h"
#include <io/utilities/block_utils.cuh>

namespace cudf {
namespace io {
namespace parquet {
namespace gpu {

#define INIT_HASH_BITS              12

struct frag_init_state_s
{
    EncColumnDesc col;
    PageFragment frag;
    uint32_t total_dupes;
    volatile uint32_t scratch_red[32];
    uint32_t dict[MAX_PAGE_FRAGMENT_SIZE];
    union {
        uint16_t u16[1 << (INIT_HASH_BITS)];
        uint32_t u32[1 << (INIT_HASH_BITS - 1)];
    } map;
};

#define LOG2_RLE_BFRSZ  9
#define RLE_BFRSZ       (1 << LOG2_RLE_BFRSZ)
#define RLE_MAX_LIT_RUN 0xfff8  // Maximum literal run for 2-byte run code

struct page_enc_state_s
{
    uint8_t *cur;               //!< current output ptr
    uint8_t *rle_out;           //!< current RLE write ptr
    uint32_t rle_run;           //!< current RLE run
    uint32_t run_val;           //!< current RLE run value
    uint32_t rle_pos;           //!< RLE encoder positions
    uint32_t rle_numvals;       //!< RLE input value count
    uint32_t rle_lit_count;
    uint32_t rle_rpt_count;
    volatile uint32_t rpt_map[4];
    volatile uint32_t scratch_red[32];
    EncPage page;
    EncColumnChunk ck;
    EncColumnDesc col;
    gpu_inflate_input_s comp_in;
    gpu_inflate_status_s comp_out;
    uint16_t vals[RLE_BFRSZ];
};


/**
 * @brief Return a 12-bit hash from a byte sequence
 */
inline __device__ uint32_t nvstr_init_hash(const uint8_t *ptr, uint32_t len)
{
    if (len != 0)
    {
        return (ptr[0] + (ptr[len - 1] << 5) + (len << 10)) & ((1 << INIT_HASH_BITS) - 1);
    }
    else
    {
        return 0;
    }
}

inline __device__ uint32_t uint32_init_hash(uint32_t v)
{
    return (v + (v >> 16)) & ((1 << INIT_HASH_BITS) - 1);
}

inline __device__ uint32_t uint64_init_hash(uint64_t v)
{
    return static_cast<uint32_t>(v + (v >> 32)) & ((1 << INIT_HASH_BITS) - 1);
}



/**
 * @brief Initializes encoder page fragments
 *
 * @param[in] frag Fragment array [fragment_id][column_id]
 * @param[in] col_desc Column description array [column_id]
 * @param[in] num_fragments Number of fragments per column
 * @param[in] num_columns Number of columns
 *
 **/
// blockDim {512,1,1}
__global__ void __launch_bounds__(512)
gpuInitPageFragments(PageFragment *frag, const EncColumnDesc *col_desc, int32_t num_fragments, int32_t num_columns, uint32_t fragment_size, uint32_t max_num_rows)
{
    __shared__ __align__(16) frag_init_state_s state_g;

    frag_init_state_s * const s = &state_g;
    uint32_t t = threadIdx.x;
    uint32_t start_row, nrows, dtype_len, dtype_len_in, dtype;

    if (t < sizeof(EncColumnDesc) / sizeof(uint32_t))
    {
        reinterpret_cast<uint32_t *>(&s->col)[t] = reinterpret_cast<const uint32_t *>(&col_desc[blockIdx.x])[t];
    }
    for (uint32_t i = 0; i < sizeof(s->map) / sizeof(uint32_t); i += 512)
    {
        if (i + t < sizeof(s->map) / sizeof(uint32_t))
            s->map.u32[i + t] = 0;
    }
    __syncthreads();
    start_row = blockIdx.y * fragment_size;
    if (!t)
    {
        s->col.num_rows = min(s->col.num_rows, max_num_rows);
        s->frag.num_rows = min(fragment_size, max_num_rows - min(start_row, max_num_rows));
        s->frag.non_nulls = 0;
        s->frag.num_dict_vals = 0;
        s->frag.fragment_data_size = 0;
        s->frag.dict_data_size = 0;
        s->total_dupes = 0;
    }
    dtype = s->col.physical_type;
    dtype_len = (dtype == INT64 || dtype == DOUBLE) ? 8 : (dtype == BOOLEAN) ? 1 : 4;
    if (dtype == INT32) {
        uint32_t converted_type = s->col.converted_type;
        dtype_len_in = (converted_type == INT_8) ? 1 : (converted_type == INT_16) ? 2 : 4;
    }
    else {
        dtype_len_in = (dtype == BYTE_ARRAY) ? sizeof(nvstrdesc_s) : dtype_len;
    }
    __syncthreads();
    nrows = s->frag.num_rows;
    for (uint32_t i = 0; i < nrows; i += 512)
    {
        const uint32_t *valid = s->col.valid_map_base;
        uint32_t row = start_row + i + t;
        uint32_t is_valid = (i + t < nrows && row < s->col.num_rows) ? (valid) ? (valid[row >> 5] >> (row & 0x1f)) & 1 : 1 : 0;
        uint32_t valid_warp = BALLOT(is_valid);
        uint32_t len, nz_pos, hash;
        if (is_valid) {
            len = dtype_len;
            if (dtype != BOOLEAN) {
                if (dtype == BYTE_ARRAY) {
                    const char *ptr = reinterpret_cast<const nvstrdesc_s *>(s->col.column_data_base)[row].ptr;
                    uint32_t count = (uint32_t)reinterpret_cast<const nvstrdesc_s *>(s->col.column_data_base)[row].count;
                    len += count;
                    hash = nvstr_init_hash(reinterpret_cast<const uint8_t *>(ptr), count);
                }
                else if (dtype_len_in == 8) {
                    hash = uint64_init_hash(reinterpret_cast<const uint64_t *>(s->col.column_data_base)[row]);
                }
                else {
                    hash = uint32_init_hash((dtype_len_in == 4) ? reinterpret_cast<const uint32_t *>(s->col.column_data_base)[row] :
                                            (dtype_len_in == 2) ? reinterpret_cast<const uint16_t *>(s->col.column_data_base)[row] :
                                                                  reinterpret_cast<const uint8_t *>(s->col.column_data_base)[row]);
                }
            }
        } else {
            len = 0;
        }
        nz_pos = s->frag.non_nulls + __popc(valid_warp & (0x7fffffffu >> (0x1fu - ((uint32_t)t & 0x1f))));
        len = WarpReduceSum32(len);
        if (!(t & 0x1f)) {
            s->scratch_red[(t >> 5) + 0] = __popc(valid_warp);
            s->scratch_red[(t >> 5) + 16] = len;
        }
        __syncthreads();
        if (t < 32) {
            uint32_t warp_pos = WarpReducePos16((t < 16) ? s->scratch_red[t] : 0, t);
            uint32_t non_nulls = SHFL(warp_pos, 0xf);
            len = WarpReduceSum16((t < 16) ? s->scratch_red[t + 16] : 0);
            if (t < 16) {
                s->scratch_red[t] = warp_pos;
            }
            if (!t) {
                s->frag.non_nulls = s->frag.non_nulls + non_nulls;
                s->frag.fragment_data_size += len;
            }
        }
        __syncthreads();
        if (is_valid && dtype != BOOLEAN) {
            uint32_t *dict_index = s->col.dict_index;
            if (t >= 32) {
                nz_pos += s->scratch_red[(t - 32) >> 5];
            }
            if (dict_index) {
                atomicAdd(&s->map.u32[hash >> 1], (hash & 1) ? 1 << 16 : 1);
                dict_index[start_row + nz_pos] = ((i + t) << INIT_HASH_BITS) | hash; // Store the hash along with the index, so we don't have to recompute it
            }
        }
    }
    __syncthreads();
    // Reorder the 16-bit local indices according to the hash values
    if (s->col.dict_index) {
#if (INIT_HASH_BITS != 12)
#error "Hardcoded for INIT_HASH_BITS=12"
#endif
        // Cumulative sum of hash map counts
        uint32_t count01 = s->map.u32[t * 4 + 0];
        uint32_t count23 = s->map.u32[t * 4 + 1];
        uint32_t count45 = s->map.u32[t * 4 + 2];
        uint32_t count67 = s->map.u32[t * 4 + 3];
        uint32_t sum01 = count01 + (count01 << 16);
        uint32_t sum23 = count23 + (count23 << 16);
        uint32_t sum45 = count45 + (count45 << 16);
        uint32_t sum67 = count67 + (count67 << 16);
        uint32_t sum_w, tmp;
        sum23 += (sum01 >> 16) * 0x10001;
        sum45 += (sum23 >> 16) * 0x10001;
        sum67 += (sum45 >> 16) * 0x10001;
        sum_w = sum67 >> 16;
        sum_w = WarpReducePos16(sum_w, t);
        if ((t & 0xf) == 0xf) {
            s->scratch_red[t >> 4] = sum_w;
        }
        __syncthreads();
        if (t < 32) {
            uint32_t sum_b = WarpReducePos32(s->scratch_red[t], t);
            s->scratch_red[t] = sum_b;
        }
        __syncthreads();
        tmp = (t >= 16) ? s->scratch_red[(t >> 4) - 1] : 0;
        sum_w = (sum_w - (sum67 >> 16) + tmp) * 0x10001;
        s->map.u32[t * 4 + 0] = sum_w + sum01 - count01;
        s->map.u32[t * 4 + 1] = sum_w + sum23 - count23;
        s->map.u32[t * 4 + 2] = sum_w + sum45 - count45;
        s->map.u32[t * 4 + 3] = sum_w + sum67 - count67;
        __syncthreads();
    }
    // Put the indices back in hash order
    if (s->col.dict_index) {
        uint32_t *dict_index = s->col.dict_index + start_row;
        uint32_t nnz = s->frag.non_nulls;
        for (uint32_t i = 0; i < nnz; i += 512) {
            uint32_t pos = 0, hash = 0, pos_old, pos_new, sh, colliding_row, val = 0;
            bool collision;
            if (i + t < nnz) {
                val = dict_index[i + t];
                hash = val & ((1 << INIT_HASH_BITS) - 1);
                sh = (hash & 1) ? 16 : 0;
                pos_old = s->map.u16[hash];
            }
            // The isolation of the atomicAdd, along with pos_old/pos_new is to guarantee deterministic behavior for the
            // first row in the hash map that will be used for early duplicate detection
            __syncthreads();
            if (i + t < nnz) {
                pos = (atomicAdd(&s->map.u32[hash >> 1], 1 << sh) >> sh) & 0xffff;
                s->dict[pos] = val;
            }
            __syncthreads();
            collision = false;
            if (i + t < nnz) {
                pos_new = s->map.u16[hash];
                collision = (pos != pos_old && pos_new > pos_old + 1);
                if (collision) {
                    colliding_row = s->dict[pos_old];
                }
            }
            __syncthreads();
            if (collision) {
                atomicMin(&s->dict[pos_old], val);
            }
            __syncthreads();
            // Resolve collision
            if (collision && val == s->dict[pos_old]) {
                s->dict[pos] = colliding_row;
            }
        }
        __syncthreads();
        // Now that the values are ordered by hash, compare every entry with the first entry in the hash map,
        // the position of the first entry can be inferred from the hash map counts
        uint32_t dupe_data_size = 0;
        for (uint32_t i = 0; i < nnz; i += 512)
        {
            const void *col_data = s->col.column_data_base;
            uint32_t ck_row = 0, ck_row_ref = 0, is_dupe = 0, dupe_mask, dupes_before;
            if (i + t < nnz)
            {
                uint32_t dict_val = s->dict[i + t];
                uint32_t hash = dict_val & ((1 << INIT_HASH_BITS) - 1);
                ck_row = start_row + (dict_val >> INIT_HASH_BITS);
                ck_row_ref = start_row + (s->dict[(hash > 0) ? s->map.u16[hash - 1] : 0] >> INIT_HASH_BITS);
                if (ck_row_ref != ck_row) {
                    if (dtype == BYTE_ARRAY) {
                        const nvstrdesc_s *ck_data = reinterpret_cast<const nvstrdesc_s *>(col_data);
                        const char *str1 = ck_data[ck_row].ptr;
                        uint32_t len1 = (uint32_t)ck_data[ck_row].count;
                        const char *str2 = ck_data[ck_row_ref].ptr;
                        uint32_t len2 = (uint32_t)ck_data[ck_row_ref].count;
                        is_dupe = nvstr_is_equal(str1, len1, str2, len2);
                        dupe_data_size += (is_dupe) ? 4 + len1 : 0;
                    }
                    else {
                        if (dtype_len_in == 8) {
                            uint64_t v1 = reinterpret_cast<const uint64_t *>(col_data)[ck_row];
                            uint64_t v2 = reinterpret_cast<const uint64_t *>(col_data)[ck_row_ref];
                            is_dupe = (v1 == v2);
                            dupe_data_size += (is_dupe) ? 8 : 0;
                        }
                        else {
                            uint32_t v1, v2;
                            if (dtype_len_in == 4) {
                                v1 = reinterpret_cast<const uint32_t *>(col_data)[ck_row];
                                v2 = reinterpret_cast<const uint32_t *>(col_data)[ck_row_ref];
                            }
                            else if (dtype_len_in == 2) {
                                v1 = reinterpret_cast<const uint16_t *>(col_data)[ck_row];
                                v2 = reinterpret_cast<const uint16_t *>(col_data)[ck_row_ref];
                            }
                            else {
                                v1 = reinterpret_cast<const uint8_t *>(col_data)[ck_row];
                                v2 = reinterpret_cast<const uint8_t *>(col_data)[ck_row_ref];
                            }
                            is_dupe = (v1 == v2);
                            dupe_data_size += (is_dupe) ? 4 : 0;
                        }
                    }
                }
            }
            dupe_mask = BALLOT(is_dupe);
            dupes_before = s->total_dupes + __popc(dupe_mask & ((2 << (t & 0x1f)) - 1));
            if (!(t & 0x1f))
            {
                s->scratch_red[t >> 5] = __popc(dupe_mask);
            }
            __syncthreads();
            if (t < 32)
            {
                uint32_t warp_dupes = (t < 16) ? s->scratch_red[t] : 0;
                uint32_t warp_pos = WarpReducePos16(warp_dupes, t);
                if (t == 0xf)
                {
                    s->total_dupes += warp_pos;
                }
                if (t < 16)
                {
                    s->scratch_red[t] = warp_pos - warp_dupes;
                }
            }
            __syncthreads();
            if (i + t < nnz)
            {
                if (!is_dupe)
                {
                    dupes_before += s->scratch_red[t >> 5];
                    s->col.dict_data[start_row + i + t - dupes_before] = ck_row - start_row;
                }
                else
                {
                    s->col.dict_index[ck_row] = ck_row_ref | (1u << 31);
                }
            }
        }
        __syncthreads();
        dupe_data_size = WarpReduceSum32(dupe_data_size);
        if (!(t & 0x1f))
        {
            s->scratch_red[t >> 5] = dupe_data_size;
        }
        __syncthreads();
        if (t < 32)
        {
            dupe_data_size = WarpReduceSum16((t < 16) ? s->scratch_red[t] : 0);
            if (!t) {
                s->frag.dict_data_size = s->frag.fragment_data_size - dupe_data_size;
                s->frag.num_dict_vals = s->frag.non_nulls - s->total_dupes;
            }
        }
    }
    __syncthreads();
    if (t < sizeof(PageFragment) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&frag[blockIdx.x * num_fragments + blockIdx.y])[t] = reinterpret_cast<uint32_t *>(&s->frag)[t];
    }
}

// blockDim {128,1,1}
__global__ void __launch_bounds__(128)
gpuInitPages(EncColumnChunk *chunks, EncPage *pages, const EncColumnDesc *col_desc, int32_t num_rowgroups, int32_t num_columns)
{
    __shared__ __align__(8) EncColumnDesc col_g;
    __shared__ __align__(8) EncColumnChunk ck_g;
    __shared__ __align__(8) PageFragment frag_g;
    __shared__ __align__(8) EncPage page_g;

    uint32_t t = threadIdx.x;
    
    if (t < sizeof(EncColumnDesc) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&col_g)[t] = reinterpret_cast<const uint32_t *>(&col_desc[blockIdx.x])[t];
    }
    if (t < sizeof(EncColumnChunk) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&ck_g)[t] = reinterpret_cast<const uint32_t *>(&chunks[blockIdx.y * num_columns + blockIdx.x])[t];
    }
    __syncthreads();
    if (t < 32) {
        uint32_t fragments_in_chunk = 0;
        uint32_t rows_in_page = 0;
        uint32_t page_size = 0;
        uint32_t num_pages = 0;
        uint32_t num_rows = 0;
        uint32_t page_start = 0;
        uint32_t page_offset = 0;
        uint32_t comp_page_offset = 0;
        uint32_t cur_row = ck_g.start_row;

        do {
            uint32_t fragment_data_size, max_page_size;
            SYNCWARP();
            if (num_rows < ck_g.num_rows) {
                if (t < sizeof(PageFragment) / sizeof(uint32_t)) {
                    reinterpret_cast<uint32_t *>(&frag_g)[t] = reinterpret_cast<const uint32_t *>(&ck_g.fragments[fragments_in_chunk])[t];
                }
            } else if (!t) {
                frag_g.fragment_data_size = 0;
                frag_g.num_rows = 0;
            }
            SYNCWARP();
            fragment_data_size = frag_g.fragment_data_size;
            max_page_size = (rows_in_page * 2 >= ck_g.num_rows) ? 256 * 1024 : (rows_in_page * 3 >= ck_g.num_rows) ? 384 * 1024 : 512 * 1024;
            if (num_rows >= ck_g.num_rows || page_size + fragment_data_size > max_page_size)
            {
                if (!t) {
                    uint32_t def_level_bits = col_g.level_bits & 0xf;
                    uint32_t def_level_size = (def_level_bits) ? 4 + 5 + ((def_level_bits * rows_in_page + 7) >> 3) : 0;
                    page_g.num_fragments = fragments_in_chunk - page_start;
                    page_g.chunk_id = blockIdx.y * num_columns + blockIdx.x;
                    page_g.page_type = DATA_PAGE;
                    page_g.hdr_size = 0;
                    page_g.max_hdr_size = 32; // Max size excluding statistics
                    page_g.max_data_size = page_size + def_level_size;
                    page_g.page_data = ck_g.uncompressed_bfr + page_offset;
                    page_g.compressed_data = ck_g.compressed_bfr + comp_page_offset;
                    page_g.start_row = cur_row;
                    page_g.num_rows = rows_in_page;
                    page_offset += page_g.max_hdr_size + page_g.max_data_size;
                    comp_page_offset += page_g.max_hdr_size + GetMaxCompressedBfrSize(page_g.max_data_size);
                    cur_row += rows_in_page;
                }
                SYNCWARP();
                if (pages && t < sizeof(EncPage) / sizeof(uint32_t)) {
                    reinterpret_cast<uint32_t *>(&pages[ck_g.first_page + num_pages])[t] = reinterpret_cast<uint32_t *>(&page_g)[t];
                }
                num_pages++;
                page_size = 0;
                rows_in_page = 0;
                page_start = fragments_in_chunk;
            }
            page_size += fragment_data_size;
            rows_in_page += frag_g.num_rows;
            num_rows += frag_g.num_rows;
            fragments_in_chunk++;
        } while (frag_g.num_rows != 0);
        if (!t) {
            ck_g.num_pages = num_pages;
            ck_g.bfr_size = page_offset;
            ck_g.compressed_size = comp_page_offset;
        }
    }
    __syncthreads();
    if (t < sizeof(EncColumnChunk) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&chunks[blockIdx.y * num_columns + blockIdx.x])[t] = reinterpret_cast<uint32_t *>(&ck_g)[t];
    }
}

/**
 * @brief Mask table representing how many consecutive repeats are needed to code a repeat run [nbits-1]
 **/
static __device__ __constant__ uint32_t kRleRunMask[16] = {
  0x00ffffff, 0x0fff, 0x00ff, 0x3f, 0x0f, 0x0f, 0x7, 0x7, 0x3, 0x3, 0x3, 0x3, 0x1, 0x1, 0x1, 0x1
};

/**
 * @brief Variable-length encode an integer
 **/
inline __device__ uint8_t *VlqEncode(uint8_t *p, uint32_t v)
{
    while (v > 0x7f) {
        *p++ = (v | 0x80);
        v >>= 7;
    }
    *p++ = v;
    return p;
}

/**
 * @brief Pack literal values in output bitstream (1,2,4,8,12 or 16 bits per value)
 **/
inline __device__ void PackLiterals(uint8_t *dst, uint32_t v, uint32_t count, uint32_t w, uint32_t t)
{
    if (t <= (count | 0x1f)) {
        if (w < 8) {
            uint32_t mask;
            if (w <= 1) {
                v |= SHFL_XOR(v, 1) << 1;
                v |= SHFL_XOR(v, 2) << 2;
                v |= SHFL_XOR(v, 4) << 4;
                mask = 0x7;
            }
            else if (w <= 2) {
                v |= SHFL_XOR(v, 1) << 2;
                v |= SHFL_XOR(v, 2) << 4;
                mask = 0x3;
            }
            else { // w=4
                v = (v << 4) | (SHFL_XOR(v, 1) & 0xf);
                mask = 0x1;
            }
            if (t < count && !(t & mask)) {
                dst[(t * w) >> 3] = v;
            }
        }
        else if (w < 12) { // w=8
            if (t < count) {
                dst[t] = v;
            }
        }
        else if (w < 16) { // w=12
            v |= SHFL_XOR(v, 1) << 12;
            if (t < count && !(t & 1)) {
                dst[(t >> 1) * 3 + 0] = v;
                dst[(t >> 1) * 3 + 1] = v >> 8;
                dst[(t >> 1) * 3 + 2] = v >> 16;
            }
        }
        else if (t < count) { // w=16
            dst[t * 2 + 0] = v;
            dst[t * 2 + 1] = v >> 8;
        }
    }
}

/**
 * @brief RLE encoder
 *
 * @param[in,out] s Page encode state
 * @param[in] numvals Total count of input values
 * @param[in] nbits number of bits per symbol (1..16)
 * @param[in] flush nonzero if last batch in block
 * @param[in] t thread id
 */
static __device__ void RleEncode(page_enc_state_s *s, uint32_t numvals, uint32_t nbits, uint32_t flush, uint32_t t)
{
    uint32_t rle_pos = s->rle_pos;
    uint32_t rle_run = s->rle_run;
    
    while (rle_pos < numvals) {
        uint32_t pos = rle_pos + t;
        uint32_t v0 = s->vals[pos & (RLE_BFRSZ-1)];
        uint32_t v1 = s->vals[(pos + 1) & (RLE_BFRSZ - 1)];
        uint32_t mask = BALLOT(pos + 1 < numvals && v0 == v1);
        uint32_t rle_lit_count, rle_rpt_count;
        if (!(t & 0x1f)) {
            s->rpt_map[t >> 5] = mask;
        }
        __syncthreads();
        if (t < 32) {
            if (rle_run > 0 && !(rle_run & 1)) {
                // Currently in a long repeat run
                uint32_t c32 = BALLOT(t >= 4 || s->rpt_map[t] != 0xffffffffu);
                if (!t) {
                    uint32_t last_idx = __ffs(c32) - 1;
                    uint32_t rpt_count = last_idx * 32 + ((last_idx < 4) ? __ffs(~s->rpt_map[last_idx]) : 0);
                    if (rpt_count && ((flush && rle_pos + rpt_count + 1 == numvals) || (rpt_count < min(numvals - rle_pos, 128)))) {
                        rpt_count++;
                    }
                    s->rle_lit_count = 0;
                    s->rle_rpt_count = rpt_count;
                }
            }
            else {
                // Not currently in a repeat run: repeat run can only start on a multiple of 8 values
                uint32_t idx8 = (t * 8) >> 5;
                uint32_t pos8 = (t * 8) & 0x1f;
                uint32_t m0 = (idx8 < 4) ? s->rpt_map[idx8] : 0;
                uint32_t m1 = (idx8 < 3) ? s->rpt_map[idx8+1] : 0;
                uint32_t needed_mask = kRleRunMask[nbits - 1];
                mask = BALLOT((__funnelshift_r(m0, m1, pos8) & needed_mask) == needed_mask);
                if (!t) {
                    uint32_t n = numvals - rle_pos;
                    uint32_t rle_run_start = (mask != 0) ? min((__ffs(mask) - 1) * 8, n) : n;
                    uint32_t rpt_len = 0;
                    if (rle_run_start < n) {
                        uint32_t idx_cur = rle_run_start >> 5;
                        uint32_t idx_ofs = rle_run_start & 0x1f;
                        while (idx_cur < 4) {
                            m0 = (idx_cur < 4) ? s->rpt_map[idx_cur] : 0;
                            m1 = (idx_cur < 3) ? s->rpt_map[idx_cur+1] : 0;
                            mask = ~__funnelshift_r(m0, m1, idx_ofs);
                            if (mask != 0)
                            {
                                rpt_len += __ffs(mask) - 1;
                                break;
                            }
                            rpt_len += 32;
                            idx_cur++;
                        }
                    }
                    s->rle_lit_count = rle_run_start;
                    s->rle_rpt_count = min(rpt_len, n - rle_run_start);
                }
            }
        }
        __syncthreads();
        rle_lit_count = s->rle_lit_count;
        rle_rpt_count = s->rle_rpt_count;
        if (rle_run != 0 && !(rle_run & 1)) {
            bool flush_run = (rle_rpt_count == 0) || (rle_lit_count != 0);
            // Currently in a repeat run
            if (rle_lit_count == 0) {
                // Run continues
                rle_run += rle_rpt_count * 2;
                rle_pos += rle_rpt_count;
                rle_rpt_count = 0;
            }
            if (flush_run || (flush && rle_pos == numvals)) {
                uint8_t *dst;
                // Output repeat run
                if (t == 0) {
                    uint32_t run_val = s->run_val;
                    dst = VlqEncode(s->rle_out, rle_run);
                    *dst++ = run_val;
                    if (nbits > 8){
                        *dst++ = run_val >> 8;
                    }
                    s->rle_out = dst;
                }
                rle_run = 0;
                __syncthreads();
            }
        }
        // Process literals
        if (rle_lit_count != 0 || (rle_run != 0 && rle_rpt_count != 0)) {
            uint32_t lit_div8;
            bool need_more_data = false;
            if (!flush && rle_pos + rle_lit_count == numvals) {
                // Wait for more data
                rle_lit_count -= min(rle_lit_count, 24);
                need_more_data = true;
            }
            if (rle_lit_count != 0) {
                lit_div8 = (rle_lit_count + ((flush && rle_pos + rle_lit_count == numvals) ? 7 : 0)) >> 3;
                if (rle_run + lit_div8 * 2 > 0x7f) {
                    lit_div8 = 0x3f - (rle_run >> 1); // Limit to fixed 1-byte header (504 literals)
                    rle_rpt_count = 0; // Defer repeat run
                }
                if (lit_div8 != 0) {
                    uint8_t *dst = s->rle_out + 1 + (rle_run >> 1) * nbits;
                    PackLiterals(dst, (rle_pos + t < numvals) ? v0 : 0, lit_div8 * 8, nbits, t);
                    rle_run = (rle_run + lit_div8 * 2) | 1;
                    rle_pos = min(rle_pos + lit_div8 * 8, numvals);
                }
            }
            if (rle_run >= ((rle_rpt_count != 0 || (flush && rle_pos == numvals)) ? 0x03 : 0x7f)) {
                __syncthreads();
                // Complete literal run
                if (!t) {
                    uint8_t *dst = s->rle_out;
                    dst[0] = rle_run; // At most 0x7f
                    dst += nbits * (rle_run >> 1);
                    s->rle_out = dst;
                }
                rle_run = 0;
            }
            if (need_more_data) {
                break;
            }
        }
        // Process repeat run
        if (rle_rpt_count != 0) {
            if (t == s->rle_lit_count) {
                s->run_val = v0;
            }
            rle_run = rle_rpt_count * 2;
            rle_pos += rle_rpt_count;
            if (rle_pos + 1 == numvals) {
                __syncthreads();
                if (flush) {
                    // Output the run
                    rle_run += 2;
                    rle_pos++;
                    if (t == 0) {
                        uint32_t run_val = s->run_val;
                        uint8_t *dst = VlqEncode(s->rle_out, rle_run);
                        *dst++ = run_val;
                        if (nbits > 8) {
                            *dst++ = run_val >> 8;
                        }
                        s->rle_out = dst;
                    }
                    rle_run = 0;
                }
                break;
            }
        }
        __syncthreads();
    }
    if (!t) {
        s->rle_run = rle_run;
        s->rle_pos = rle_pos;
        s->rle_numvals = numvals;
    }
}


// blockDim(128, 1, 1)
__global__ void __launch_bounds__(128, 8)
gpuEncodePages(EncPage *pages, const EncColumnChunk *chunks, gpu_inflate_input_s *comp_in, gpu_inflate_status_s *comp_out, uint32_t start_page)
{
    __shared__ __align__(8) page_enc_state_s state_g;

    page_enc_state_s * const s = &state_g;
    uint32_t t = threadIdx.x;
    uint32_t dtype, dtype_len_in, dtype_len_out, dict_bits;

    if (t < sizeof(EncPage) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&s->page)[t] = reinterpret_cast<uint32_t *>(&pages[start_page + blockIdx.x])[t];
    }
    __syncthreads();
    if (t < sizeof(EncColumnChunk) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&s->ck)[t] = reinterpret_cast<const uint32_t *>(&chunks[s->page.chunk_id])[t];
    }
    __syncthreads();
    if (t < sizeof(EncColumnDesc) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&s->col)[t] = reinterpret_cast<const uint32_t *>(s->ck.col_desc)[t];
    }
    __syncthreads();
    if (!t) {
        s->cur = s->page.page_data + s->page.max_hdr_size;
    }
    __syncthreads();
    // Encode NULLs
    if (s->page.page_type != DICTIONARY_PAGE && s->col.level_bits != 0) {
        const uint32_t *valid = s->col.valid_map_base;
        uint32_t def_lvl_bits = s->col.level_bits & 0xf;
        if (def_lvl_bits != 0) {
            if (!t) {
                s->rle_run = 0;
                s->rle_pos = 0;
                s->rle_numvals = 0;
                s->rle_out = s->cur + 4;
            }
            __syncthreads();
            while (s->rle_numvals < s->page.num_rows) {
                uint32_t rle_numvals = s->rle_numvals;
                uint32_t nrows = min(s->page.num_rows - rle_numvals, RLE_BFRSZ - (rle_numvals - s->rle_pos));
                uint32_t row = s->page.start_row + rle_numvals + t;
                uint32_t def_lvl = (row < s->col.num_rows) ? (valid) ? (valid[row >> 5] >> (row & 0x1f)) & 1 : 1 : 0;
                s->vals[(rle_numvals + t) & (RLE_BFRSZ-1)] = def_lvl;
                __syncthreads();
                rle_numvals += nrows;
                RleEncode(s, rle_numvals, def_lvl_bits, (rle_numvals == s->page.num_rows), t);
                __syncthreads();
            }
            if (t < 32) {
                uint8_t *cur = s->cur;
                uint8_t *rle_out = s->rle_out;
                if (t < 4) {
                    uint32_t rle_bytes = (uint32_t)(rle_out - cur);
                    cur[t] = rle_bytes >> (t * 8);
                }
                SYNCWARP();
                if (t == 0) {
                    s->cur = rle_out;
                }
            }
        }
    }
    // Encode data values
    __syncthreads();
    dtype = s->col.physical_type;
    dtype_len_out = (dtype == INT64 || dtype == DOUBLE) ? 8 : (dtype == BOOLEAN) ? 1 : 4;
    if (dtype == INT32) {
        uint32_t converted_type = s->col.converted_type;
        dtype_len_in = (converted_type == INT_8) ? 1 : (converted_type == INT_16) ? 2 : 4;
    }
    else {
        dtype_len_in = (dtype == BYTE_ARRAY) ? sizeof(nvstrdesc_s) : dtype_len_out;
    }
    dict_bits = (dtype == BOOLEAN) ? 1 : 0;
    if (t == 0) {
        uint8_t *dst = s->cur;
        s->rle_run = 0;
        s->rle_pos = 0;
        s->rle_numvals = 0;
        s->rle_out = dst;
        if (dict_bits != 0 && dtype != BOOLEAN) {
            dst[0] = dict_bits;
            s->rle_out = dst + 1;
        }
    }
    __syncthreads();
    for (uint32_t cur_row = 0; cur_row < s->page.num_rows; ) {
        uint32_t nrows = min(s->page.num_rows - cur_row, 128);
        const uint32_t *valid = s->col.valid_map_base;
        uint32_t row = s->page.start_row + cur_row + t;
        uint32_t is_valid = (row < s->col.num_rows) ? (valid) ? (valid[row >> 5] >> (row & 0x1f)) & 1 : 1 : 0;
        uint32_t warp_valids = BALLOT(is_valid);
        uint32_t len, pos;

        cur_row += nrows;
        if (dict_bits != 0) {
            // Dictionary encoding
            uint32_t v, rle_numvals;

            pos = __popc(warp_valids & ((1 << (t & 0x1f)) - 1));
            if (!(t & 0x1f)) {
                s->scratch_red[t >> 5] = __popc(warp_valids);
            }
            __syncthreads();
            if (t < 32) {
                s->scratch_red[t] = WarpReducePos4((t < 4) ? s->scratch_red[t] : 0, t);
            }
            __syncthreads();
            pos = pos + ((t >= 32) ? s->scratch_red[(t - 32) >> 5] : 0);
            rle_numvals = s->rle_numvals + s->scratch_red[3];
            v = reinterpret_cast<const uint8_t *>(s->col.column_data_base)[row]; // NOTE: Assuming boolean for now
            if (is_valid) {
                s->vals[(rle_numvals + pos) & (RLE_BFRSZ - 1)] = v;
            }
            RleEncode(s, rle_numvals, dict_bits, (cur_row == s->page.num_rows), t);
            __syncthreads();
        }
        else {
            // Non-dictionary encoding
            uint8_t *dst = s->cur;

            if (is_valid) {
                len = dtype_len_out;
                if (dtype == BYTE_ARRAY) {
                    len += (uint32_t)reinterpret_cast<const nvstrdesc_s *>(s->col.column_data_base)[row].count;
                }
            }
            else {
                len = 0;
            }
            pos = WarpReducePos32(len, t);
            if ((t & 0x1f) == 0x1f) {
                s->scratch_red[t >> 5] = pos;
            }
            __syncthreads();
            if (t < 32) {
                s->scratch_red[t] = WarpReducePos4((t < 4) ? s->scratch_red[t] : 0, t);
            }
            __syncthreads();
            if (t == 0) {
                s->cur = dst + s->scratch_red[3];
            }
            pos = pos + ((t >= 32) ? s->scratch_red[(t - 32) >> 5] : 0) - len;
            if (is_valid) {
                const uint8_t *src8 = reinterpret_cast<const uint8_t *>(s->col.column_data_base) + row * (size_t)dtype_len_in;
                switch (dtype) {
                case INT32:
                case FLOAT: {
                        int32_t v;
                        if (dtype_len_in == 4)
                            v = *reinterpret_cast<const int32_t *>(src8);
                        else if (dtype_len_in == 2)
                            v = *reinterpret_cast<const int16_t *>(src8);
                        else
                            v = *reinterpret_cast<const int8_t *>(src8);
                        dst[pos + 0] = v;
                        dst[pos + 1] = v >> 8;
                        dst[pos + 2] = v >> 16;
                        dst[pos + 3] = v >> 24;
                    }
                    break;
                case INT64:
                case DOUBLE:
                    memcpy(dst + pos, src8, 8);
                    break;
                case BYTE_ARRAY: {
                        const char *str_data = reinterpret_cast<const nvstrdesc_s *>(src8)->ptr;
                        uint32_t v = len - 4; // string length
                        dst[pos + 0] = v;
                        dst[pos + 1] = v >> 8;
                        dst[pos + 2] = v >> 16;
                        dst[pos + 3] = v >> 24;
                        if (v != 0)
                            memcpy(dst + pos + 4, str_data, v);
                    }
                    break;
                }
            }
            __syncthreads();
        }
    }
    if (t == 0) {
        uint8_t *base = s->page.page_data + s->page.max_hdr_size;
        uint32_t actual_data_size = static_cast<uint32_t>(s->cur - base);
        uint32_t compressed_bfr_size = GetMaxCompressedBfrSize(s->page.max_data_size);
        s->page.max_data_size = actual_data_size;
        s->comp_in.srcDevice = base;
        s->comp_in.srcSize = actual_data_size;
        s->comp_in.dstDevice = s->page.compressed_data + s->page.max_hdr_size;
        s->comp_in.dstSize = compressed_bfr_size;
        s->comp_out.bytes_written = 0;
        s->comp_out.status = ~0;
        s->comp_out.reserved = 0;
    }
    __syncthreads();
    if (t < sizeof(EncPage) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&pages[start_page + blockIdx.x])[t] = reinterpret_cast<uint32_t *>(&s->page)[t];
    }
    if (comp_in && t < sizeof(gpu_inflate_input_s) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&comp_in[blockIdx.x])[t] = reinterpret_cast<uint32_t *>(&s->comp_in)[t];
    }
    if (comp_out && t < sizeof(gpu_inflate_status_s) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&comp_out[blockIdx.x])[t] = reinterpret_cast<uint32_t *>(&s->comp_out)[t];
    }
}


// blockDim(128, 1, 1)
__global__ void __launch_bounds__(128)
gpuDecideCompression(EncColumnChunk *chunks, const EncPage *pages, const gpu_inflate_status_s *comp_out)
{
    __shared__ __align__(8) EncColumnChunk ck_g;
    __shared__ __align__(4) unsigned int error_count;

    uint32_t t = threadIdx.x;
    uint32_t uncompressed_data_size = 0;
    uint32_t compressed_data_size = 0;
    uint32_t first_page, num_pages;

    if (t < sizeof(EncColumnChunk) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&ck_g)[t] = reinterpret_cast<const uint32_t *>(&chunks[blockIdx.x])[t];
    }
    if (t == 0) {
        atomicAnd(&error_count, 0);
    }
    __syncthreads();
    first_page = ck_g.first_page;
    num_pages = ck_g.num_pages;
    for (uint32_t page = t; page < num_pages; page++) {
        uint32_t page_data_size = pages[first_page + page].max_data_size;
        uncompressed_data_size += page_data_size;
        if (comp_out) {
            compressed_data_size += (uint32_t)comp_out[page].bytes_written;
            if (comp_out[page].status != 0) {
                atomicAdd(&error_count, 1);
            }
        }
    }
    __syncthreads();
    if (t == 0) {
        bool is_compressed;
        if (comp_out) {
            uint32_t compression_error = atomicAdd(&error_count, 0);
            is_compressed = (!compression_error && compressed_data_size < uncompressed_data_size);
        }
        else {
            is_compressed = false;
        }
        chunks[blockIdx.x].is_compressed = is_compressed;
        chunks[blockIdx.x].bfr_size = uncompressed_data_size;
        chunks[blockIdx.x].compressed_size = (is_compressed) ? compressed_data_size : uncompressed_data_size;
    }

}


/**
 * Minimal thrift compact protocol support
 **/
inline __device__ uint8_t *cpw_put_uint32(uint8_t *p, uint32_t v) {
    while (v > 0x7f) {
        *p++ = v | 0x80;
        v >>= 7;
    }
    *p++ = v;
    return p;
}

inline __device__ uint8_t *cpw_put_uint64(uint8_t *p, uint64_t v) {
    while (v > 0x7f) {
        *p++ = v | 0x80;
        v >>= 7;
    }
    *p++ = v;
    return p;
}

inline __device__ uint8_t *cpw_put_int32(uint8_t *p, int32_t v) {
    int32_t s = (v < 0);
    return cpw_put_uint32(p, (v ^ -s) * 2 + s);
}

inline __device__ uint8_t *cpw_put_int64(uint8_t *p, int64_t v) {
    int64_t s = (v < 0);
    return cpw_put_uint64(p, (v ^ -s) * 2 + s);
}

inline __device__ uint8_t *cpw_put_fldh(uint8_t *p, int f, int cur, int t) {
    if (f > cur && f <= cur + 15) {
        *p++ = ((f - cur) << 4) | t;
        return p;
    }
    else {
        *p++ = t;
        return cpw_put_int32(p, f);
    }
}

#define CPW_BEGIN_STRUCT(hdr_start) {               \
    uint8_t *p = hdr_start;                         \
    int cur_fld = 0;                                \

#define CPW_FLD_STRUCT_BEGIN(f)                     \
    p = cpw_put_fldh(p, f, cur_fld, ST_FLD_STRUCT); \
    cur_fld = 0;                                    \

#define CPW_FLD_STRUCT_END(f)                       \
    *p++ = 0;                                       \
    cur_fld = f;                                    \

#define CPW_FLD_INT32(f, v)                         \
    p = cpw_put_fldh(p, f, cur_fld, ST_FLD_I32);    \
    p = cpw_put_int32(p, v);                        \
    cur_fld = f;                                    \

#define CPW_FLD_INT64(f, v)                         \
    p = cpw_put_fldh(p, f, cur_fld, ST_FLD_I64);    \
    p = cpw_put_int64(p, v);                        \
    cur_fld = f;                                    \

#define CPW_END_STRUCT(hdr_end)                     \
    *p++ = 0;                                       \
    hdr_end = p;                                    \
    }                                               \

// blockDim(128, 1, 1)
__global__ void __launch_bounds__(128)
gpuEncodePageHeaders(EncPage *pages, const EncColumnChunk *chunks, const gpu_inflate_status_s *comp_out, uint32_t start_page)
{
    //__shared__ __align__(8) EncColumnDesc col_g;
    __shared__ __align__(8) EncColumnChunk ck_g;
    __shared__ __align__(8) EncPage page_g;

    uint32_t t = threadIdx.x;

    if (t < sizeof(EncPage) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&page_g)[t] = reinterpret_cast<uint32_t *>(&pages[start_page + blockIdx.x])[t];
    }
    __syncthreads();
    if (t < sizeof(EncColumnChunk) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&ck_g)[t] = reinterpret_cast<const uint32_t *>(&chunks[page_g.chunk_id])[t];
    }
    /*__syncthreads();
    if (t < sizeof(EncColumnDesc) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&col_g)[t] = reinterpret_cast<const uint32_t *>(ck_g.col_desc)[t];
    }*/
    __syncthreads();
    if (!t) {
        uint8_t *hdr_start, *hdr_end;
        uint32_t compressed_page_size, uncompressed_page_size;

        uncompressed_page_size = page_g.max_data_size;
        if (ck_g.is_compressed) {
            hdr_start = page_g.compressed_data;
            compressed_page_size = (uint32_t)comp_out[blockIdx.x].bytes_written;
            page_g.max_data_size = compressed_page_size;
        }
        else {
            hdr_start = page_g.page_data;
            compressed_page_size = uncompressed_page_size;
        }
        CPW_BEGIN_STRUCT(hdr_start)
            int page_type = DATA_PAGE;
            CPW_FLD_INT32(1, page_type)
            CPW_FLD_INT32(2, uncompressed_page_size)
            CPW_FLD_INT32(3, compressed_page_size)
            if (page_type == DATA_PAGE) {
                // DataPageHeader
                CPW_FLD_STRUCT_BEGIN(5)
                    CPW_FLD_INT32(1, page_g.num_rows)   // NOTE: num_values != num_rows for list types
                    CPW_FLD_INT32(2, PLAIN)             // TODO: encoding
                    CPW_FLD_INT32(3, RLE)               // definition_level_encoding
                    CPW_FLD_INT32(4, RLE)               // repetition_level_encoding
                    // TODO: page-level statistics
                CPW_FLD_STRUCT_END(5)
            }
            else {
                // DictionaryPageHeader
                CPW_FLD_STRUCT_BEGIN(7)
                    CPW_FLD_INT32(1, page_g.num_rows)   // FIXME: num_values in dictionary
                    CPW_FLD_INT32(2, PLAIN)             // Dictionary values always using PLAIN encoding
                CPW_FLD_STRUCT_END(7)
            }
        CPW_END_STRUCT(hdr_end)
        page_g.hdr_size = (uint32_t)(hdr_end - hdr_start);
    }
    __syncthreads();
    if (t < sizeof(EncPage) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&pages[start_page + blockIdx.x])[t] = reinterpret_cast<uint32_t *>(&page_g)[t];
    }
}


// blockDim(1024, 1, 1)
__global__ void __launch_bounds__(1024)
gpuGatherPages(EncColumnChunk *chunks, const EncPage *pages)
{
    __shared__ __align__(8) EncColumnChunk ck_g;
    __shared__ __align__(8) EncPage page_g;

    uint32_t t = threadIdx.x;
    uint8_t *dst, *dst_base;
    const EncPage *first_page;
    uint32_t num_pages, uncompressed_size;

    if (t < sizeof(EncColumnChunk) / sizeof(uint32_t)) {
        reinterpret_cast<uint32_t *>(&ck_g)[t] = reinterpret_cast<const uint32_t *>(&chunks[blockIdx.x])[t];
    }
    __syncthreads();
    first_page = &pages[ck_g.first_page];
    num_pages = ck_g.num_pages;
    dst = (ck_g.is_compressed) ? ck_g.compressed_bfr : ck_g.uncompressed_bfr;
    dst_base = dst;
    uncompressed_size = ck_g.bfr_size;

    for (uint32_t page = 0; page < num_pages; page++) {
        const uint8_t *src;
        uint32_t hdr_len, data_len;

        if (t < sizeof(EncPage) / sizeof(uint32_t)) {
            reinterpret_cast<uint32_t *>(&page_g)[t] = reinterpret_cast<const uint32_t *>(&first_page[page])[t];
        }
        __syncthreads();
        src = (ck_g.is_compressed) ? page_g.compressed_data : page_g.page_data;
        // Copy page header
        hdr_len = page_g.hdr_size;
        memcpy_block<1024, true>(dst, src, hdr_len, t);
        src += page_g.max_hdr_size;
        dst += hdr_len;
        // Copy page data
        uncompressed_size += hdr_len;
        data_len = page_g.max_data_size;
        memcpy_block<1024, true>(dst, src, data_len, t);
        dst += data_len;
        __syncthreads();
    }
    if (t == 0) {
        chunks[blockIdx.x].bfr_size = uncompressed_size;
        chunks[blockIdx.x].compressed_size = (dst - dst_base);
    }
}



/**
 * @brief Launches kernel for initializing encoder page fragments
 *
 * @param[in] frag Fragment array [column_id][fragment_id]
 * @param[in] col_desc Column description array [column_id]
 * @param[in] num_fragments Number of fragments per column
 * @param[in] num_columns Number of columns
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t InitPageFragments(PageFragment *frag, const EncColumnDesc *col_desc, int32_t num_fragments, int32_t num_columns, uint32_t fragment_size, uint32_t num_rows, cudaStream_t stream)
{
    dim3 dim_grid(num_columns, num_fragments);  // 1 threadblock per fragment
    gpuInitPageFragments <<< dim_grid, 512, 0, stream >>> (frag, col_desc, num_fragments, num_columns, fragment_size, num_rows);
    return cudaSuccess;
}


/**
 * @brief Launches kernel for initializing encoder data pages
 *
 * @param[in,out] chunks Column chunks [rowgroup][column]
 * @param[out] pages Encode page array (null if just counting pages)
 * @param[in] col_desc Column description array [column_id]
 * @param[in] num_rowgroups Number of fragments per column
 * @param[in] num_columns Number of columns
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t InitEncoderPages(EncColumnChunk *chunks, EncPage *pages, const EncColumnDesc *col_desc, int32_t num_rowgroups, int32_t num_columns, cudaStream_t stream)
{
    dim3 dim_grid(num_columns, num_rowgroups);  // 1 threadblock per rowgroup
    gpuInitPages <<< dim_grid, 128, 0, stream >>> (chunks, pages, col_desc, num_rowgroups, num_columns);
    return cudaSuccess;
}


/**
 * @brief Launches kernel for packing column data into parquet pages
 *
 * @param[in,out] pages Device array of EncPages (unordered)
 * @param[in] chunks Column chunks
 * @param[in] num_pages Number of pages
 * @param[in] start_page First page to encode in page array
 * @param[out] comp_in Optionally initializes compressor input params
 * @param[out] comp_out Optionally initializes compressor output params
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t EncodePages(EncPage *pages, const EncColumnChunk *chunks, uint32_t num_pages, uint32_t start_page,
                        gpu_inflate_input_s *comp_in, gpu_inflate_status_s *comp_out, cudaStream_t stream)
{
    gpuEncodePages <<< num_pages, 128, 0, stream >>> (pages, chunks, comp_in, comp_out, start_page);
    return cudaSuccess;
}


/**
 * @brief Launches kernel to make the compressed vs uncompressed chunk-level decision
 *
 * @param[in,out] chunks Column chunks
 * @param[in] pages Device array of EncPages (unordered)
 * @param[in] num_chunks Number of column chunks
 * @param[in] comp_out Compressor status
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t DecideCompression(EncColumnChunk *chunks, const EncPage *pages, uint32_t num_chunks,
                              const gpu_inflate_status_s *comp_out, cudaStream_t stream)
{
    gpuDecideCompression <<< num_chunks, 128, 0, stream >>>(chunks, pages, comp_out);
    return cudaSuccess;
}


/**
 * @brief Launches kernel to encode page headers
 *
 * @param[in,out] pages Device array of EncPages
 * @param[in] chunks Column chunks
 * @param[in] num_pages Number of pages
 * @param[in] start_page First page to encode in page array
 * @param[in] comp_out Compressor status or nullptr if no compression
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t EncodePageHeaders(EncPage *pages, const EncColumnChunk *chunks, uint32_t num_pages,
                              uint32_t start_page, const gpu_inflate_status_s *comp_out, cudaStream_t stream)
{
    gpuEncodePageHeaders <<< num_pages, 128, 0, stream >>> (pages, chunks, comp_out, start_page);
    return cudaSuccess;
}

/**
 * @brief Launches kernel to gather pages to a single contiguous block per chunk
 *
 * @param[in,out] chunks Column chunks
 * @param[in] pages Device array of EncPages
 * @param[in] num_chunks Number of column chunks
 * @param[in] stream CUDA stream to use, default 0
 *
 * @return cudaSuccess if successful, a CUDA error code otherwise
 **/
cudaError_t GatherPages(EncColumnChunk *chunks, const EncPage *pages, uint32_t num_chunks, cudaStream_t stream)
{
    gpuGatherPages <<< num_chunks, 1024, 0, stream >>>(chunks, pages);
    return cudaSuccess;
}


} // namespace gpu
} // namespace parquet
} // namespace io
} // namespace cudf
