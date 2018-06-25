#! /usr/bin/env python
# -*- coding: utf-8 -*-

"""Test nested attention models (pytorch)."""

from __future__ import absolute_import
from __future__ import division
from __future__ import print_function

import sys
import time
import unittest
import argparse

import torch
torch.manual_seed(1623)
torch.cuda.manual_seed_all(1623)

sys.path.append('../../../../../')
from src.models.pytorch_v3.attention.nested_attention_seq2seq import NestedAttentionSeq2seq
from src.models.pytorch_v3.data_parallel import CustomDataParallel
from src.models.test.data import generate_data, idx2char, idx2word
from src.utils.measure_time_func import measure_time
from src.utils.evaluation.edit_distance import compute_wer
from src.bin.training.utils.learning_rate_controller import Controller

parser = argparse.ArgumentParser()
parser.add_argument('--ngpus', type=int, default=0,
                    help='the number of GPUs (negative value indicates CPU)')
args = parser.parse_args()


class TestCharseqAttention(unittest.TestCase):

    def test(self):
        print("Nested Attention Working check.")

        # TODO: multi-gpu version does not work

        self.check(fix_second_decoder=True)

        # Usage character-level decoder states
        self.check(usage_dec_sub='softmax')
        self.check(logits_injection=True, usage_dec_sub='softmax')
        self.check(usage_dec_sub='update_decoder')
        self.check(usage_dec_sub='all')

        # gating mechanism
        self.check(usage_dec_sub='all', gating=True)

        # beam search
        self.check(usage_dec_sub='softmax', beam_width=2)
        self.check(usage_dec_sub='update_decoder', beam_width=2)
        self.check(usage_dec_sub='all', beam_width=2)

        self.check(main_loss_weight=0)

        # Regularization
        self.check(relax_context_vec_dec=True)

        # char initialization
        # self.check(main_loss_weight=0)

        # Attend to word-level backward decoder
        self.check(second_pass=True)

        # Forward word decoder + backward char decoder
        self.check(backward_sub=True)

        # Attention regularization
        self.check(att_reg_weight=1)

        # Attention smoothing
        self.check(dec_attend_temperature=2)
        self.check(dec_sigmoid_smoothing=True)

    @measure_time
    def check(self, usage_dec_sub='all', att_reg_weight=0,
              main_loss_weight=0.5, ctc_loss_weight_sub=0,
              dec_attend_temperature=1, dec_sigmoid_smoothing=False,
              backward_sub=False, num_heads=1, second_pass=False,
              relax_context_vec_dec=False, logits_injection=False,
              gating=False, beam_width=1, fix_second_decoder=False):

        print('==================================================')
        print('  usage_dec_sub: %s' % usage_dec_sub)
        print('  att_reg_weight: %.2f' % att_reg_weight)
        print('  main_loss_weight: %.2f' % main_loss_weight)
        print('  ctc_loss_weight_sub: %.2f' % ctc_loss_weight_sub)
        print('  dec_attend_temperature: %s' % str(dec_attend_temperature))
        print('  dec_sigmoid_smoothing: %s' % str(dec_sigmoid_smoothing))
        print('  backward_sub: %s' % str(backward_sub))
        print('  num_heads: %d' % num_heads)
        print('  second_pass: %s' % str(second_pass))
        print('  relax_context_vec_dec: %s' % str(relax_context_vec_dec))
        print('  logits_injection: %s' % str(logits_injection))
        print('  gating: %s' % str(gating))
        print('  gating: %s' % str(fix_second_decoder))
        print('==================================================')

        # Load batch data
        xs, ys, ys_sub = generate_data(label_type='word_char',
                                       batch_size=2 * args.ngpus)

        # Load model
        model = NestedAttentionSeq2seq(
            input_size=xs[0].shape[-1],
            encoder_type='lstm',
            encoder_bidirectional=True,
            encoder_num_units=256,
            encoder_num_proj=0,
            encoder_num_layers=2,
            encoder_num_layers_sub=2,
            attention_type='location',
            attention_dim=128,
            decoder_type='lstm',
            decoder_num_units=256,
            decoder_num_layers=1,
            decoder_num_units_sub=256,
            decoder_num_layers_sub=1,
            embedding_dim=64,
            embedding_dim_sub=32,
            dropout_input=0.1,
            dropout_encoder=0.1,
            dropout_decoder=0.1,
            dropout_embedding=0.1,
            main_loss_weight=main_loss_weight,
            sub_loss_weight=0.5 if ctc_loss_weight_sub == 0 else 0,
            num_classes=11,
            num_classes_sub=27 if not second_pass else 11,
            parameter_init_distribution='uniform',
            parameter_init=0.1,
            recurrent_weight_orthogonal=False,
            init_forget_gate_bias_with_one=True,
            subsample_list=[True, False],
            subsample_type='drop',
            init_dec_state='first',
            sharpening_factor=1,
            logits_temperature=1,
            sigmoid_smoothing=False,
            ctc_loss_weight_sub=ctc_loss_weight_sub,
            attention_conv_num_channels=10,
            attention_conv_width=201,
            num_stack=1,
            num_skip=1,
            splice=1,
            conv_channels=[],
            conv_kernel_sizes=[],
            conv_strides=[],
            poolings=[],
            batch_norm=False,
            scheduled_sampling_prob=0.1,
            scheduled_sampling_max_step=200,
            label_smoothing_prob=0.1,
            weight_noise_std=0,
            encoder_residual=False,
            encoder_dense_residual=False,
            decoder_residual=False,
            decoder_dense_residual=False,
            decoding_order='bahdanau',
            bottleneck_dim=256,
            bottleneck_dim_sub=256,
            backward_sub=backward_sub,
            num_heads=num_heads,
            num_heads_sub=num_heads,
            num_heads_dec=num_heads,
            usage_dec_sub=usage_dec_sub,
            att_reg_weight=att_reg_weight,
            dec_attend_temperature=dec_attend_temperature,
            dec_sigmoid_smoothing=dec_attend_temperature,
            relax_context_vec_dec=relax_context_vec_dec,
            dec_attention_type='content',
            logits_injection=logits_injection,
            gating=gating)

        # Count total parameters
        for name in sorted(list(model.num_params_dict.keys())):
            num_params = model.num_params_dict[name]
            print("%s %d" % (name, num_params))
        print("Total %.2f M parameters" % (model.total_parameters / 1000000))

        # Define optimizer
        learning_rate = 1e-3
        model.set_optimizer('adam',
                            learning_rate_init=learning_rate,
                            weight_decay=1e-6,
                            lr_schedule=False,
                            factor=0.1,
                            patience_epoch=5)

        # Define learning rate controller
        lr_controller = Controller(learning_rate_init=learning_rate,
                                   backend='pytorch',
                                   decay_type='compare_metric',
                                   decay_start_epoch=20,
                                   decay_rate=0.9,
                                   decay_patient_epoch=10,
                                   lower_better=True)

        # GPU setting
        if args.ngpus >= 1:
            model = CustomDataParallel(
                model, device_ids=list(range(0, args.ngpus, 1)),
                benchmark=True)
            model.cuda()

        # Train model
        max_step = 300
        start_time_step = time.time()
        for step in range(max_step):

            # Step for parameter update
            model.module.optimizer.zero_grad()
            if args.ngpus > 1:
                torch.cuda.empty_cache()
            if second_pass:
                loss, acc = model(xs, ys)
            else:
                loss, loss_main, loss_sub, acc_main, acc_sub = model(
                    xs, ys, ys_sub)
            if args.ngpus > 1:
                loss.backward(torch.ones(args.ngpus))
            else:
                loss.backward()
            loss.detach()
            if model.module.torch_version < 0.4:
                torch.nn.utils.clip_grad_norm(model.module.parameters(), 5)
            else:
                torch.nn.utils.clip_grad_norm_(model.module.parameters(), 5)
            torch.nn.utils.clip_grad_norm(model.module.parameters(), 5)
            model.module.optimizer.step()

            if fix_second_decoder and step == 100:
                model.module.fix_second_decoder()

            if (step + 1) % 10 == 0:
                # Compute loss
                if second_pass:
                    loss, acc = model(xs, ys, is_eval=True)
                else:
                    loss, loss_main, loss_sub, acc_main, acc_sub = model(
                        xs, ys, ys_sub, is_eval=True)
                loss = loss.data[0] if model.module.torch_version < 0.4 else loss.item(
                )

                best_hyps, _, best_hyps_sub, _, _, perm_idx = model.module.decode(
                    xs, beam_width, max_decode_len=30,
                    beam_width_sub=beam_width, max_decode_len_sub=60)

                str_hyp = idx2word(best_hyps[0][:-1])
                str_ref = idx2word(ys[0])
                if second_pass:
                    str_hyp_sub = idx2word(best_hyps_sub[0][:-1])
                    str_ref_sub = idx2word(ys[0])
                else:
                    str_hyp_sub = idx2char(best_hyps_sub[0][:-1])
                    str_ref_sub = idx2char(ys_sub[0])

                # Compute accuracy
                try:
                    wer = compute_wer(ref=str_ref.split('_'),
                                      hyp=str_hyp.split('_'),
                                      normalize=True)[0]
                    if second_pass:
                        wer_bwd = compute_wer(ref=str_ref.split('_'),
                                              hyp=str_hyp_sub.split('_'),
                                              normalize=True)[0]
                    else:
                        cer = compute_wer(
                            ref=list(str_ref_sub.replace('_', '')),
                            hyp=list(str_hyp_sub.replace('_', '')),
                            normalize=True)[0]
                except:
                    wer = 100
                    if second_pass:
                        wer_bwd = 100
                    else:
                        cer = 100

                duration_step = time.time() - start_time_step
                if second_pass:
                    print('Step %d: loss=%.2f/acc=%.2f/wer=%.2f%%/wer(bwd)=%.2f%%/lr=%.5f (%.2f sec)' %
                          (step + 1, loss, acc, wer, wer_bwd, learning_rate, duration_step))
                else:
                    print('Step %d: loss=%.2f(%.2f/%.2f)/acc=%.2f/%.2f/wer=%.2f%%/cer=%.2f%%/lr=%.5f (%.2f sec)' %
                          (step + 1, loss, loss_main, loss_sub, acc_main, acc_sub,
                           wer, cer, learning_rate, duration_step))

                start_time_step = time.time()

                # Visualize
                print('Ref: %s' % str_ref)
                print('Hyp (word): %s' % str_hyp)
                print('Hyp (char): %s' % str_hyp_sub)

                metric = wer_bwd if second_pass else cer
                if metric < 1:
                    print('Modle is Converged.')
                    break

                # Update learning rate
                model.module.optimizer, learning_rate = lr_controller.decay_lr(
                    optimizer=model.module.optimizer,
                    learning_rate=learning_rate,
                    epoch=step,
                    value=wer)


if __name__ == "__main__":
    if sys.argv:
        del sys.argv[1:]

    unittest.main()
