#!/bin/bash

# Copyright 2018 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

model=
gpu=

### path to save preproecssed data
data=/n/sd8/inaguma/corpus/timit

epoch=-1
batch_size=1
beam_width=5
min_len_ratio=0.0
max_len_ratio=1.0
length_penalty=0.0
coverage_penalty=0.6
coverage_threshold=0.0

. ./cmd.sh
. ./path.sh
. utils/parse_options.sh

set -e
set -u
set -o pipefail

if [ -z ${gpu} ]; then
  echo "Error: set GPU number." 1>&2
  echo "Usage: ./run.sh --gpu 0" 1>&2
  exit 1
fi
gpu=`echo ${gpu} | cut -d "," -f 1`

for set in dev test; do
  decode_dir=${model}/decode_${set}_ep${epoch}_beam${beam_width}_lp${length_penalty}_cp${coverage_penalty}_${min_len_ratio}_${max_len_ratio}
  mkdir -p ${decode_dir}

  CUDA_VISIBLE_DEVICES=${gpu} ../../../neural_sp/bin/asr/eval.py \
    --eval_sets ${data}/dataset/${set}.csv \
    --model ${model} \
    --epoch ${epoch} \
    --batch_size ${batch_size} \
    --beam_width ${beam_width} \
    --max_len_ratio ${max_len_ratio} \
    --min_len_ratio ${min_len_ratio} \
    --length_penalty ${length_penalty} \
    --coverage_penalty ${coverage_penalty} \
    --coverage_threshold ${coverage_threshold} \
    --decode_dir ${decode_dir} || exit 1;

  echo ${set}
  local/score_sclite.sh ${decode_dir} > ${decode_dir}/RESULTS
  cat ${decode_dir}/RESULTS
done
