#!/bin/bash

# Copyright 2018 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

echo ============================================================================
echo "                                   WSJ                                     "
echo ============================================================================

stage=0
gpu=

### path to save preproecssed data
export data=/n/sd8/inaguma/corpus/wsj

### vocabulary
unit=char        # or word or char
vocab_size=300
wp_type=unigram  # or bpe (for wordpiece)

#########################
# ASR configuration
#########################
### topology
enc_type=blstm
enc_nunits=320
enc_nprojs=0
enc_nlayers=4
enc_residual=
subsample="1_2_2_1"
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
ctc_fc_list="320"

### optimization
batch_size=50
optimizer=adam
learning_rate=1e-3
nepochs=25
convert_to_sgd_epoch=20
print_step=100
decay_start_epoch=10
decay_rate=0.9
decay_patient_epoch=0
not_improved_patient_epoch=5
eval_start_epoch=5
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
ctc_weight=0.2
bwd_weight=0.0

#########################
# RNNLM configuration
#########################

### path to save the model
model=/n/sd8/inaguma/result/wsj

### path to the model directory to restart training
rnnlm_resume=
resume=

### path to original data
wsj0=/n/rd21/corpora_1/WSJ/wsj0
wsj1=/n/rd21/corpora_1/WSJ/wsj1

# Sometimes, we have seen WSJ distributions that do not have subdirectories
# like '11-13.1', but instead have 'doc', 'si_et_05', etc. directly under the
# wsj0 or wsj1 directories. In such cases, try the following:
CSTR_WSJTATATOP=/n/rd21/corpora_1/WSJ
# $CSTR_WSJTATATOP must contain a 'wsj0' and a 'wsj1' subdirectory for this to work.

directory_type=cstr # or original

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

train_set=train_si284
dev_set=test_dev93
test_set="test_eval92"

if [ ${unit} = char ]; then
  vocab_size=
fi
if [ ${unit} != wp ]; then
  wp_type=
fi


if [ ${stage} -le 0 ] && [ ! -e .done_stage_0 ]; then
  echo ============================================================================
  echo "                       Data Preparation (stage:0)                          "
  echo ============================================================================

  case ${directory_type} in
    original) local/wsj_data_prep.sh ${wsj0}/??-{?,??}.? ${wsj1}/??-{?,??}.? || exit 1; ;;
    cstr) local/cstr_wsj_data_prep.sh $CSTR_WSJTATATOP || exit 1; ;;
  esac

  # "nosp" refers to the dictionary before silence probabilities and pronunciation
  # probabilities are added.
  local/wsj_prepare_dict.sh --dict-suffix "_nosp" || exit 1;
  local/wsj_format_data.sh --lang-suffix "_nosp" || exit 1;
  case ${directory_type} in
    original) local/wsj_extend_dict.sh --dict-suffix "_nosp" ${wsj1}/13-32.1 || exit 1; ;;
    cstr) local/cstr_wsj_extend_dict.sh --dict-suffix "_nosp" $CSTR_WSJTATATOP/wsj1/doc/ || exit 1; ;;
  esac

  touch .done_stage_0 && echo "Finish data preparation (stage: 0)."
fi

if [ ${stage} -le 1 ] && [ ! -e .done_stage_1 ]; then
  echo ============================================================================
  echo "                    Feature extranction (stage:1)                          "
  echo ============================================================================

  for x in train_si284 test_dev93 test_eval92; do
    steps/make_fbank.sh --nj 16 --cmd "$train_cmd" --write_utt2num_frames true \
      ${data}/${x} ${data}/log/make_fbank/${x} ${data}/fbank || exit 1;
  done

  # Compute global CMVN
  compute-cmvn-stats scp:${data}/${train_set}/feats.scp ${data}/${train_set}/cmvn.ark || exit 1;

  # Apply global CMVN & dump features
  for x in ${train_set} ${dev_set} ${test_set}; do
    dump_dir=${data}/dump/${x}
    dump_feat.sh --cmd "$train_cmd" --nj 16 --add_deltadelta false \
      ${data}/${x}/feats.scp ${data}/${train_set}/cmvn.ark ${data}/log/dump_feat/${x} ${dump_dir} || exit 1;
  done

  touch .done_stage_1 && echo "Finish feature extranction (stage: 1)."
fi

dict=${data}/dict/${train_set}_${unit}${wp_type}${vocab_size}.txt; mkdir -p ${data}/dict
wp_model=${data}/dict/${train_set}_${wp_type}${vocab_size}
if [ ${stage} -le 2 ] && [ ! -e .done_stage_2_${unit}${wp_type}${vocab_size} ]; then
  echo ============================================================================
  echo "                      Dataset preparation (stage:2)                        "
  echo ============================================================================

  # Make a dictionary
  echo "<unk> 1" > ${dict}  # <unk> must be 1, 0 will be used for "blank" in CTC
  echo "<eos> 2" >> ${dict}  # <sos> and <eos> share the same index
  echo "<pad> 3" >> ${dict}
  if [ ${unit} = char ]; then
    echo "<space> 4" >> ${dict}
  fi
  offset=`cat ${dict} | wc -l`
  echo "Making a dictionary..."
  if [ ${unit} = wp ]; then
    cut -f 2- -d " " ${data}/${train_set}/text > ${data}/dict/input.txt
    spm_train --input=${data}/dict/input.txt --vocab_size=${vocab_size} --model_type=${wp_type} --model_prefix=${wp_model} --input_sentence_size=100000000 --character_coverage=1.0
    spm_encode --model=${wp_model}.model --output_format=piece < ${data}/dict/input.txt | tr ' ' '\n' | sort | uniq | awk -v offset=${offset} '{print $0 " " NR+offset-1}' >> ${dict}
  else
    text2dict.py ${data}/${train_set}/text --unit ${unit} --vocab_size ${vocab_size} \
      --wp_type ${wp_type} --wp_model ${wp_model} | \
      sort | uniq | grep -v -e '^\s*$' | awk -v offset=${offset} '{print $0 " " NR+offset-1}' >> ${dict} || exit 1;
  fi
  echo "vocab size:" `cat ${dict} | wc -l`

  # Make datset csv files
  mkdir -p ${data}/dataset_csv
  for x in ${train_set} ${dev_set}; do
    echo "Making a csv file for ${x}..."
    dump_dir=${data}/dump/${x}
    make_dataset_csv.sh --feat ${dump_dir}/feats.scp --unit ${unit} --wp_model ${wp_model} \
      ${data}/${x} ${dict} > ${data}/dataset_csv/${x}_${unit}${wp_type}${vocab_size}.csv || exit 1;
  done
  for x in ${test_set}; do
    dump_dir=${data}/dump/${x}
    make_dataset_csv.sh --is_test true --feat ${dump_dir}/feats.scp --unit ${unit} \
      ${data}/${x} ${dict} > ${data}/dataset_csv/${x}_${unit}${wp_type}${vocab_size}.csv || exit 1;
  done

  touch .done_stage_2_${unit}${wp_type}${vocab_size} && echo "Finish creating dataset (stage: 2)."
fi


mkdir -p ${model}
if [ ${stage} -le 3 ]; then
  echo ============================================================================
  echo "                      RNNLM Training stage (stage:3)                       "
  echo ============================================================================

  echo "Start RNNLM training..."

  # Extend dictionary for the external text data
  # ${data}/local/dict_nosp_larger/cleaned.gz

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
    --dev_set ${data}/dataset_csv/${dev_set}_${unit}${wp_type}${vocab_size}.csv \
    --eval_sets ${data}/dataset_csv/${test_set}_${unit}${wp_type}${vocab_size}.csv \
    --dict ${dict} \
    --wp_model ${wp_model}.model \
    --model ${model}/asr \
    --label_type ${unit} \
    --enc_type ${enc_type} \
    --enc_nunits ${enc_nunits} \
    --enc_nprojs ${enc_nprojs} \
    --enc_nlayers ${enc_nlayers} \
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
    --bwd_weight ${bwd_weight} || exit 1;
    # --resume ${resume} || exit 1;

  echo "Finish model training (stage: 4)."
fi
