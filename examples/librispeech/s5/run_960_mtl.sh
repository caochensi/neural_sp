#!/bin/bash

# Copyright 2018 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

echo ============================================================================
echo "                              LibriSpeech                                 "
echo ============================================================================

stage=0
gpu=

### path to save preproecssed data
export data=/n/sd8/inaguma/corpus/librispeech

### vocabulary
unit=word        # or wp
vocab_size=30000
wp_type=unigram  # or bpe (for wordpiece)
unit_sub=char


#########################
# ASR configuration
#########################
### topology
enc_type=blstm
enc_nunits=320
enc_nprojs=0
enc_nlayers=5
enc_nlayers_sub=4
enc_residual=
subsample="1_2_2_2_1"
subsample_type=max_pool
attn_type=location
attn_dim=320
attn_nheads=1
dec_type=lstm
dec_nunits=320
dec_nprojs=0
dec_nlayers=1
dec_residual=
emb_dim=320
ctc_fc_list=""
ctc_fc_list_sub=""

### optimization
batch_size=40
optimizer=adam
learning_rate=1e-3
nepochs=25
convert_to_sgd_epoch=20
print_step=500
decay_start_epoch=10
decay_rate=0.9
decay_patient_epoch=0
not_improved_patient_epoch=5
eval_start_epoch=1
warmup_start_learning_rate=1e-4
warmup_step=0
warmup_epoch=0

### initialization
param_init=0.1
param_init_dist=uniform
pretrained_model=

### regularization
dropout_in=0.0
dropout_enc=0.2
dropout_dec=0.2
dropout_emb=0.2
dropout_att=0.0
weight_decay=1e-6
ss_prob=0.2
ss_type=constant
lsm_prob=0.1

### MTL
ctc_weight=0.0
ctc_weight_sub=0.0
bwd_weight=0.0
main_task_weight=0.8

#########################
# RNNLM configuration
#########################

### path to save the model
model=/n/sd8/inaguma/result/librispeech

### path to the model directory to restart training
rnnlm_resume=
resume=

# path to download data
data_download_path=/n/rd21/corpora_7/librispeech/

### data size
data_size=960

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
ngpus=`echo ${gpu} | tr "," "\n" | wc -l`
rnnlm_gpu=`echo ${gpu} | cut -d "," -f 1`

# Base url for downloads.
data_url=www.openslr.org/resources/12
lm_url=www.openslr.org/resources/11

train_set=train_${data_size}
dev_set=dev_${data_size}
test_set="dev_clean dev_other test_clean test_other"

if [ ${unit} != wp ]; then
  wp_type=
fi


if [ ${stage} -le 0 ] && [ ! -e .done_stage_0_${data_size} ]; then
  echo ============================================================================
  echo "                       Data Preparation (stage:0)                          "
  echo ============================================================================

  # download data
  # mkdir -p ${data}
  # for part in dev-clean test-clean dev-other test-other train-clean-100 train-clean-360 train-other-500; do
  #   local/download_and_untar.sh ${data_download_path} ${data_url} ${part} || exit 1;
  # done

  # download the LM resources
  # local/download_lm.sh ${lm_url} ${data}/local/lm || exit 1;

  # format the data as Kaldi data directories
  for part in dev-clean test-clean dev-other test-other train-clean-100 train-clean-360 train-other-500; do
    # use underscore-separated names in data directories.
    local/data_prep.sh ${data_download_path}/LibriSpeech/${part} ${data}/$(echo ${part} | sed s/-/_/g) || exit 1;
  done

  # lowercasing
  for x in dev_clean test_clean dev_other test_other train_clean_100 train_clean_360 train_other_500; do
      cp ${data}/${x}/text ${data}/${x}/text.tmp
      paste -d "" <(cut -f 1 -d" " ${data}/${x}/text.tmp) \
                  <(awk '{$1=""; print tolower($0)}' ${data}/${x}/text.tmp) > ${data}/${x}/text
      rm ${data}/${x}/text.tmp
  done

  touch .done_stage_0_${data_size} && echo "Finish data preparation (stage: 0)."
fi

if [ ${stage} -le 1 ] && [ ! -e .done_stage_1_${data_size} ]; then
  echo ============================================================================
  echo "                    Feature extranction (stage:1)                          "
  echo ============================================================================

  for x in dev_clean test_clean dev_other test_other train_clean_100 train_clean_360 train_other_500; do
    steps/make_fbank.sh --nj 16 --cmd "$train_cmd" --write_utt2num_frames true \
      ${data}/${x} ${data}/log/make_fbank/${x} ${data}/fbank || exit 1;
  done

  utils/combine_data.sh --extra_files "utt2num_frames" ${data}/${train_set} ${data}/train_clean_100 ${data}/train_clean_360 ${data}/train_other_500 || exit 1;
  utils/combine_data.sh --extra_files "utt2num_frames" ${data}/${dev_set} ${data}/dev_clean ${data}/dev_other || exit 1;

  # Compute global CMVN
  compute-cmvn-stats scp:${data}/${train_set}/feats.scp ${data}/${train_set}/cmvn.ark || exit 1;

  # Apply global CMVN & dump features
  for x in ${train_set} ${dev_set}; do
    dump_dir=${data}/dump/${x}
    dump_feat.sh --cmd "$train_cmd" --nj 16 --add_deltadelta false \
      ${data}/${x}/feats.scp ${data}/${train_set}/cmvn.ark ${data}/log/dump_feat/${x} ${dump_dir} || exit 1;
  done
  for x in ${test_set}; do
    dump_dir=${data}/dump/${x}_${data_size}
    dump_feat.sh --cmd "$train_cmd" --nj 16 --add_deltadelta false \
      ${data}/${x}/feats.scp ${data}/${train_set}/cmvn.ark ${data}/log/dump_feat/${x}_${data_size} ${dump_dir} || exit 1;
  done

  touch .done_stage_1_${data_size} && echo "Finish feature extranction (stage: 1)."
fi

dict=${data}/dict/${train_set}_${unit}${wp_type}${vocab_size}.txt; mkdir -p ${data}/dict/
dict_sub=${data}/dict/${train_set}_${unit_sub}.txt
wp_model=${data}/dict/${train_set}_${wp_type}${vocab_size}

if [ ! -f ${dict} ]; then
  echo "There is no file such as "${dict}
  exit 1
fi

if [ ! -f ${dict_sub} ]; then
  echo "There is no file such as "${dict_sub}
  exit 1
fi

mkdir -p ${model}
if [ ${stage} -le 3 ]; then
  echo ============================================================================
  echo "                      RNNLM Training stage (stage:3)                       "
  echo ============================================================================

  echo "Start RNNLM training..."

  # NOTE: support only a single GPU for RNNLM training
  CUDA_VISIBLE_DEVICES=${rnnlm_gpu} ../../../neural_sp/bin/lm/train.py \
    --ngpus 1 \
    --train_set ${data}/dataset_csv/${train_set}_${unit}${wp_type}${vocab_size}.csv \
    --dev_set ${data}/dataset_csv/${dev_set}_${unit}${wp_type}${vocab_size}.csv \
    --dict ${dict} \
    --wp_model ${wp_model}.model \
    --config ${rnnlm_config} \
    --model ${model}/rnnlm \
    --label_type ${unit} || exit 1;
    # --resume ${rnnlm_resume} || exit 1;

  echo "Finish RNNLM training (stage: 3)."
fi

if [ ${stage} -le 4 ]; then
  echo ============================================================================
  echo "                       ASR Training stage (stage:4)                        "
  echo ============================================================================

  echo "Start ASR training..."

  CUDA_VISIBLE_DEVICES=${gpu} ../../../neural_sp/bin/asr/train.py \
    --ngpus ${ngpus} \
    --train_set ${data}/dataset_csv/${train_set}_${unit}${wp_type}${vocab_size}.csv \
    --train_set_sub ${data}/dataset_csv/${train_set}_${unit_sub}.csv \
    --dev_set ${data}/dataset_csv/${dev_set}_${unit}${wp_type}${vocab_size}.csv \
    --dev_set_sub ${data}/dataset_csv/${dev_set}_${unit_sub}.csv \
    --dict ${dict} \
    --dict_sub ${dict_sub} \
    --wp_model ${wp_model}.model \
    --model ${model}/asr \
    --label_type ${unit} \
    --label_type_sub ${unit_sub} \
    --enc_type ${enc_type} \
    --enc_nunits ${enc_nunits} \
    --enc_nprojs ${enc_nprojs} \
    --enc_nlayers ${enc_nlayers} \
    --enc_nlayers_sub ${enc_nlayers_sub} \
    --enc_residual ${enc_residual} \
    --subsample ${subsample} \
    --subsample_type ${subsample_type} \
    --attn_type ${attn_type} \
    --attn_dim ${attn_dim} \
    --attn_nheads ${attn_nheads} \
    --dec_type ${dec_type} \
    --dec_nunits ${dec_nunits} \
    --dec_nprojs ${dec_nprojs} \
    --dec_nlayers ${dec_nlayers} \
    --dec_residual ${dec_residual} \
    --emb_dim ${emb_dim} \
    --ctc_fc_list ${ctc_fc_list} \
    --batch_size ${batch_size} \
    --optimizer ${optimizer} \
    --learning_rate ${learning_rate} \
    --nepochs ${nepochs} \
    --convert_to_sgd_epoch ${convert_to_sgd_epoch} \
    --print_step ${print_step} \
    --decay_start_epoch ${decay_start_epoch} \
    --decay_rate ${decay_rate} \
    --decay_patient_epoch ${decay_patient_epoch} \
    --not_improved_patient_epoch ${not_improved_patient_epoch} \
    --eval_start_epoch ${eval_start_epoch} \
    --warmup_start_learning_rate ${warmup_start_learning_rate} \
    --warmup_step ${warmup_step} \
    --warmup_epoch ${warmup_epoch} \
    --param_init ${param_init} \
    --param_init_dist ${param_init_dist} \
    --pretrained_model ${pretrained_model} \
    --dropout_in ${dropout_in} \
    --dropout_enc ${dropout_enc} \
    --dropout_dec ${dropout_dec} \
    --dropout_emb ${dropout_emb} \
    --dropout_att ${dropout_att} \
    --weight_decay ${weight_decay} \
    --ss_prob ${ss_prob} \
    --ss_type ${ss_type} \
    --lsm_prob ${lsm_prob} \
    --ctc_weight ${ctc_weight} \
    --ctc_weight_sub ${ctc_weight_sub} \
    --bwd_weight ${bwd_weight} \
    --main_task_weight ${main_task_weight} || exit 1;
    # --resume ${resume} || exit 1;

  echo "Finish model training (stage: 4)."
fi
