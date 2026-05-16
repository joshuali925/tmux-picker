@include "join" # gawk 4.1 was released in 2013

BEGIN {
    highlight_patterns = ENVIRON["PICKER_PATTERNS"]
    # Only build the blacklist regex when user actually configured one — the
    # check runs on every match and is otherwise pure overhead.
    user_blacklist = ENVIRON["PICKER_BLACKLIST_PATTERNS"]
    have_blacklist = (user_blacklist != "")
    if (have_blacklist) {
        blacklist = "(^\x1b\\[[0-9;]{1,9}m|^|[[:space:]:<>)(&#'\"])"user_blacklist"$"
    }

    hint_format = ENVIRON["PICKER_HINT_FORMAT"]
    hint_format_nocolor = ENVIRON["PICKER_HINT_FORMAT_NOCOLOR"]
    hint_format_len = length(sprintf(hint_format_nocolor, ""))
    highlight_format = ENVIRON["PICKER_HIGHLIGHT_FORMAT"]
    compound_format = hint_format highlight_format

    # tty_by_idx[fi] is the picker tty for the fi-th capture file (in arg order).
    split(ENVIRON["TTY_LIST"], tty_by_idx, "\n")

    n_unique = 0
    n_files = 0
    n_lines = 0

    # Pre-compute the outer-group index for each top-level alternation arm
    # so per-match prefix lookup walks a small fixed list instead of every
    # key in matches[].
    compute_outer_indices(highlight_patterns)
}

function compute_outer_indices(pat,    n, i, c, c2, j, depth, group_idx, in_class) {
    n = length(pat)
    depth = 0
    group_idx = 0
    in_class = 0
    n_outer = 0
    for (i = 1; i <= n; i++) {
        c = substr(pat, i, 1)
        if (c == "\\") { i++; continue }
        if (in_class) {
            # POSIX subclasses [:foo:] / [=foo=] / [.foo.] — skip past the closing
            # so the inner ] doesn't end the outer class prematurely.
            if (c == "[") {
                c2 = substr(pat, i+1, 1)
                if (c2 == ":" || c2 == "=" || c2 == ".") {
                    j = index(substr(pat, i+2), c2 "]")
                    if (j > 0) { i = i + 2 + j; continue }
                }
            }
            if (c == "]") in_class = 0
            continue
        }
        if (c == "[") {
            in_class = 1
            # First char inside a class is a literal ] (after optional ^).
            c2 = substr(pat, i+1, 1)
            if (c2 == "^") { i++; c2 = substr(pat, i+1, 1) }
            if (c2 == "]") i++
            continue
        }
        if (c == "(") {
            depth++
            group_idx++
            if (depth == 1) {
                n_outer++
                outer_indices[n_outer] = group_idx
            }
        } else if (c == ")") {
            depth--
        }
    }
}

FNR == 1 {
    n_files++
    file_first_line[n_files] = n_lines + 1
}

{
    # SOH/STX are reserved as placeholder delimiters in line_buffer.
    if (index($0, "\x01") || index($0, "\x02")) gsub(/[\x01\x02]/, "", $0)
    line = $0;
    output_line = "";
    post_match = line;
    skipped_prefix = "";

    while (match(line, highlight_patterns, matches)) {
        pre_match = skipped_prefix substr(line, 1, RSTART - 1);
        post_match = substr(line, RSTART + RLENGTH);
        line_match = matches[0]

        if (!have_blacklist || line_match !~ blacklist) {
            # Top-level alternation is ((prefix)body); only the matched arm
            # populates capture entries. Walk the precomputed outer indices
            # and pick the first one that participated in this match.
            outer_idx = 0
            for (k = 1; k <= n_outer; k++) {
                oi = outer_indices[k]
                if (matches[oi, "start"] > 0) { outer_idx = oi; break }
            }
            if (outer_idx > 0) {
                prefix_idx = outer_idx + 1
                line_match = substr(line_match, 1 + matches[prefix_idx, "length"])
                pre_match = pre_match matches[prefix_idx]
            }

            # strip embedded color escapes so paste output is clean and the
            # highlight renders contiguously across color resets — most matches
            # don't contain escapes, so skip the gsub via a cheap index() probe.
            if (index(line_match, "\x1b") > 0) gsub(/\x1b\[[0-9;]{1,9}m/, "", line_match);

            idx = match_idx_by_text[line_match]
            if (!idx) {
                n_unique++
                idx = n_unique
                match_idx_by_text[line_match] = idx
                unique_match_text[n_unique] = line_match
            }

            # Fix colors broken by the hints highlighting.
            # This is mostly needed to keep prompts intact, so fix first ~500 chars only.
            # Skip entirely when pre_match has no escapes — the common case.
            if (length(output_line) < 500 && index(pre_match, "\x1b") > 0) {
                num_colors = split(pre_match, arr, /\x1b\[[0-9;]{1,9}m/, colors);
                if (num_colors > 1) {
                    post_match = join(colors, 1, num_colors - 1, "") post_match;
                }
            }

            # Defer rendering: store match index inline; resolved at END once
            # the hint pool is chosen based on total unique-match count.
            output_line = output_line pre_match "\x01" idx "\x02";
            skipped_prefix = "";
        } else {
            skipped_prefix = pre_match line_match; # we need it only to fix colors
        }
        line = post_match;
    }

    n_lines++
    line_buffer[n_lines] = "\n" (output_line skipped_prefix post_match);
}

END {
    # hint pools generated by gen_hints.py
    if (n_unique <= 17) {
        split("s a d f j k l e w c m v p g h r u", HINTS);
    } else if (n_unique <= 30) {
        split("s a d f j k l e w c m v p g h r us ua ud uf uj uk ul ue uw uc um uv up ug", HINTS);
    } else if (n_unique <= 50) {
        split("s a d f j k l e w c m v p g hs ha rs ra rd rf rj rk rl re rw rc rm rv rp rg rh rr ru us ua ud uf uj uk ul ue uw uc um uv up ug uh ur uu", HINTS);
    } else if (n_unique <= 80) {
        split("s a d f j k l e w c m v p gs ga gd gf gj gk gl ge gw gc gm gv gp gg gh gr hs ha hd hf hj hk hl he hw hc hm hv hp hg hh hr hu rs ra rd rf rj rk rl re rw rc rm rv rp rg rh rr ru us ua ud uf uj uk ul ue uw uc um uv up ug uh ur uu", HINTS);
    } else if (n_unique <= 110) {
        split("s a d f j k l e w c m vs va vd vf vj vk vl ve vw vc vm vv vp vg ps pa pd pf pj pk pl pe pw pc pm pv pp pg ph pr pu gs ga gd gf gj gk gl ge gw gc gm gv gp gg gh gr gu hs ha hd hf hj hk hl he hw hc hm hv hp hg hh hr hu rs ra rd rf rj rk rl re rw rc rm rv rp rg rh rr ru us ua ud uf uj uk ul ue uw uc um uv up ug uh ur uu", HINTS);
    } else if (n_unique <= 150) {
        split("s a d f j k l e ws wa wd wf wj wk cs ca cd cf cj ck cl ce cw cc cm cv cp cg ch cr cu ms ma md mf mj mk ml me mw mc mm mv mp mg mh mr mu vs va vd vf vj vk vl ve vw vc vm vv vp vg vh vr vu ps pa pd pf pj pk pl pe pw pc pm pv pp pg ph pr pu gs ga gd gf gj gk gl ge gw gc gm gv gp gg gh gr gu hs ha hd hf hj hk hl he hw hc hm hv hp hg hh hr hu rs ra rd rf rj rk rl re rw rc rm rv rp rg rh rr ru us ua ud uf uj uk ul ue uw uc um uv up ug uh ur uu", HINTS);
    } else if (n_unique <= 200) {
        split("s a d f j ks ka kd kf kj kk kl ke ls la ld lf lj lk ll le lw lc lm lv lp lg lh lr lu es ea ed ef ej ek el ee ew ec em ev ep eg eh er eu ws wa wd wf wj wk wl we ww wc wm wv wp wg wh wr wu cs ca cd cf cj ck cl ce cw cc cm cv cp cg ch cr cu ms ma md mf mj mk ml me mw mc mm mv mp mg mh mr mu vs va vd vf vj vk vl ve vw vc vm vv vp vg vh vr vu ps pa pd pf pj pk pl pe pw pc pm pv pp pg ph pr pu gs ga gd gf gj gk gl ge gw gc gm gv gp gg gh gr gu hs ha hd hf hj hk hl he hw hc hm hv hp hg hh hr hu rs ra rd rf rj rk rl re rw rc rm rv rp rg rh rr ru us ua ud uf uj uk ul ue uw uc um uv up ug uh ur uu", HINTS);
    } else if (n_unique <= 300) {
        split("ss sa sd sf sj sk sl se sw sc sm sv sp sg sh sr su as aa ad af aj ak al ae aw ac am av ap ag ah ar au ds da dd df dj dk dl de dw dc dm dv dp dg dh dr du fs fa fd ff fj fk fl fe fw fc fm fv fp fg fh fr fu js ja jd jf jj jk jl je jw jc jm jv jp jg jh jr ju ks ka kd kf kj kk kl ke kw kc km kv kp kg kh kr ku ls la ld lf lj lk ll le lw lc lm lv lp lg lh lr lu es ea ed ef ej ek el ee ew ec em ev ep eg eh er eu ws wa wd wf wj wk wl we ww wc wm wv wp wg wh wr wu cs ca cd cf cj ck cl ce cw cc cm cv cp cg ch cr cu ms ma md mf mj mk ml me mw mc mm mv mp mg mh mr mu vs va vd vf vj vk vl ve vw vc vm vv vp vg vh vr vu ps pa pd pf pj pk pl pe pw pc pm pv pp pg ph pr pu gs ga gd gf gj gk gl ge gw gc gm gv gp gg gh gr gu hs ha hd hf hj hk hl he hw hc hm hv hp hg hh hr hu rs ra rd rf rj rk rl re rw rc rm rv rp rg rh rr ru us ua ud uf uj uk ul ue uw uc um uv up ug uh ur uus uua uud uuf uuj uuk uul uue uuw uuc uum uuv", HINTS);
    } else if (n_unique <= 500) {
        split("ss sa sd sf sj sk sl se sw sc sm sv sp sg sh sr su as aa ad af aj ak al ae aw ac am av ap ag ah ar au ds da dd df dj dk dl de dw dc dm dv dp dg dh dr du fs fa fd ff fj fk fl fe fw fc fm fv fp fg fh fr fu js ja jd jf jj jk jl je jw jc jm jv jp jg jh jr ju ks ka kd kf kj kk kl ke kw kc km kv kp kg kh kr ku ls la ld lf lj lk ll le lw lc lm lv lp lg lh lr lu es ea ed ef ej ek el ee ew ec em ev ep eg eh er eu ws wa wd wf wj wk wl we ww wc wm wv wp wg wh wr wu cs ca cd cf cj ck cl ce cw cc cm cv cp cg ch cr cu ms ma md mf mj mk ml me mw mc mm mv mp mg mh mr mu vs va vd vf vj vk vl ve vw vc vm vv vp vg vh vr vu ps pa pd pf pj pk pl pe pw pc pm pv pp pg ph pr pu gs ga gd gf gj gk gl ge gw gc gm gv gp gg gh gr gu hs ha hd hf hj hk hl he hw hc hm hv hp hg hh hr hu rs ra rd rf rj rk rl re rw rc rm rv rp rg rh rr ru us ua ud ufs ufa ufd uff ujs uja ujd ujf ujj ujk ujl uje ujw ujc ujm ujv ujp ujg ujh ujr uju uks uka ukd ukf ukj ukk ukl uke ukw ukc ukm ukv ukp ukg ukh ukr uku uls ula uld ulf ulj ulk ull ule ulw ulc ulm ulv ulp ulg ulh ulr ulu ues uea ued uef uej uek uel uee uew uec uem uev uep ueg ueh uer ueu uws uwa uwd uwf uwj uwk uwl uwe uww uwc uwm uwv uwp uwg uwh uwr uwu ucs uca ucd ucf ucj uck ucl uce ucw ucc ucm ucv ucp ucg uch ucr ucu ums uma umd umf umj umk uml ume umw umc umm umv ump umg umh umr umu uvs uva uvd uvf uvj uvk uvl uve uvw uvc uvm uvv uvp uvg uvh uvr uvu ups upa upd upf upj upk upl upe upw upc upm upv upp upg uph upr upu ugs uga ugd ugf ugj ugk ugl uge ugw ugc ugm ugv ugp ugg ugh ugr ugu uhs uha uhd uhf uhj uhk uhl uhe uhw uhc uhm uhv uhp uhg uhh uhr uhu urs ura urd urf urj urk url ure urw urc urm urv urp urg urh urr uru uus uua uud uuf uuj uuk uul uue uuw uuc uum uuv uup uug uuh uur uuu", HINTS);
    } else {
        split("ss sa sd sf sj sk sl se sw sc sm sv sp sg sh sr su as aa ad af aj ak al ae aw ac am av ap ag ah ar au ds da dd df dj dk dl de dw dc dm dv dp dg dh dr du fs fa fd ff fj fk fl fe fw fc fm fv fp fg fh fr fu js ja jd jf jj jk jl je jw jc jm jv jp jg jh jr ju ks ka kd kf kj kk kl ke kw kc km kv kp kg kh kr ku ls la ld lf lj lk ll le lw lc lm lv lp lg lh lr lu es ea ed ef ej ek el ee ew ec em ev ep eg eh er eu ws wa wd wf wj wk wl we ww wc wm wv wp wg wh wr wu cs ca cd cf cj ck cl ce cw cc cm cv cp cg ch cr cu ms ma md mf mj mk ml me mw mc mm mv mp mg mh mr mu vs va vd vf vj vk vl ve vw vc vm vv vp vg vh vr vu ps pa pd pf pj pk pl pe pw pc pm pv pp pg ph pr pu gs ga gd gf gj gk gl ge gw gc gm gv gp gg gh gr gu hs ha hd hf hj hk hls hla hld hlf hlj hlk hll hle hes hea hed hef hej hek hel hee hew hec hem hev hep heg heh her heu hws hwa hwd hwf hwj hwk hwl hwe hww hwc hwm hwv hwp hwg hwh hwr hwu hcs hca hcd hcf hcj hck hcl hce hcw hcc hcm hcv hcp hcg hch hcr hcu hms hma hmd hmf hmj hmk hml hme hmw hmc hmm hmv hmp hmg hmh hmr hmu hvs hva hvd hvf hvj hvk hvl hve hvw hvc hvm hvv hvp hvg hvh hvr hvu hps hpa hpd hpf hpj hpk hpl hpe hpw hpc hpm hpv hpp hpg hph hpr hpu hgs hga hgd hgf hgj hgk hgl hge hgw hgc hgm hgv hgp hgg hgh hgr hgu hhs hha hhd hhf hhj hhk hhl hhe hhw hhc hhm hhv hhp hhg hhh hhr hhu hrs hra hrd hrf hrj hrk hrl hre hrw hrc hrm hrv hrp hrg hrh hrr hru hus hua hud huf huj huk hul hue huw huc hum huv hup hug huh hur huu rss rsa rsd rsf rsj rsk rsl rse rsw rsc rsm rsv rsp rsg rsh rsr rsu ras raa rad raf raj rak ral rae raw rac ram rav rap rag rah rar rau rds rda rdd rdf rdj rdk rdl rde rdw rdc rdm rdv rdp rdg rdh rdr rdu rfs rfa rfd rff rfj rfk rfl rfe rfw rfc rfm rfv rfp rfg rfh rfr rfu rjs rja rjd rjf rjj rjk rjl rje rjw rjc rjm rjv rjp rjg rjh rjr rju rks rka rkd rkf rkj rkk rkl rke rkw rkc rkm rkv rkp rkg rkh rkr rku rls rla rld rlf rlj rlk rll rle rlw rlc rlm rlv rlp rlg rlh rlr rlu res rea red ref rej rek rel ree rew rec rem rev rep reg reh rer reu rws rwa rwd rwf rwj rwk rwl rwe rww rwc rwm rwv rwp rwg rwh rwr rwu rcs rca rcd rcf rcj rck rcl rce rcw rcc rcm rcv rcp rcg rch rcr rcu rms rma rmd rmf rmj rmk rml rme rmw rmc rmm rmv rmp rmg rmh rmr rmu rvs rva rvd rvf rvj rvk rvl rve rvw rvc rvm rvv rvp rvg rvh rvr rvu rps rpa rpd rpf rpj rpk rpl rpe rpw rpc rpm rpv rpp rpg rph rpr rpu rgs rga rgd rgf rgj rgk rgl rge rgw rgc rgm rgv rgp rgg rgh rgr rgu rhs rha rhd rhf rhj rhk rhl rhe rhw rhc rhm rhv rhp rhg rhh rhr rhu rrs rra rrd rrf rrj rrk rrl rre rrw rrc rrm rrv rrp rrg rrh rrr rru rus rua rud ruf ruj ruk rul rue ruw ruc rum ruv rup rug ruh rur ruu uss usa usd usf usj usk usl use usw usc usm usv usp usg ush usr usu uas uaa uad uaf uaj uak ual uae uaw uac uam uav uap uag uah uar uau uds uda udd udf udj udk udl ude udw udc udm udv udp udg udh udr udu ufs ufa ufd uff ufj ufk ufl ufe ufw ufc ufm ufv ufp ufg ufh ufr ufu ujs uja ujd ujf ujj ujk ujl uje ujw ujc ujm ujv ujp ujg ujh ujr uju uks uka ukd ukf ukj ukk ukl uke ukw ukc ukm ukv ukp ukg ukh ukr uku uls ula uld ulf ulj ulk ull ule ulw ulc ulm ulv ulp ulg ulh ulr ulu ues uea ued uef uej uek uel uee uew uec uem uev uep ueg ueh uer ueu uws uwa uwd uwf uwj uwk uwl uwe uww uwc uwm uwv uwp uwg uwh uwr uwu ucs uca ucd ucf ucj uck ucl uce ucw ucc ucm ucv ucp ucg uch ucr ucu ums uma umd umf umj umk uml ume umw umc umm umv ump umg umh umr umu uvs uva uvd uvf uvj uvk uvl uve uvw uvc uvm uvv uvp uvg uvh uvr uvu ups upa upd upf upj upk upl upe upw upc upm upv upp upg uph upr upu ugs uga ugd ugf ugj ugk ugl uge ugw ugc ugm ugv ugp ugg ugh ugr ugu uhs uha uhd uhf uhj uhk uhl uhe uhw uhc uhm uhv uhp uhg uhh uhr uhu urs ura urd urf urj urk url ure urw urc urm urv urp urg urh urr uru uus uua uud uuf uuj uuk uul uue uuw uuc uum uuv uup uug uuh uur uuu", HINTS);
    }

    hint_lookup = ""
    for (i = 1; i <= n_unique; i++) {
        hint = HINTS[i]
        text = unique_match_text[i]
        hint_lookup = hint_lookup hint ":" text "\n"
        hint_len = length(hint) + hint_format_len
        truncated = substr(text, hint_len + 1, length(text) - hint_len)
        rendered_by_idx[i] = sprintf(compound_format, hint, truncated)
    }

    for (fi = 1; fi <= n_files; fi++) {
        out = tty_by_idx[fi]
        # Build the entire pane payload first, then write in one printf —
        # avoids ~tens of thousands of tiny writes to a tty.
        pane_out = "\x1b[2J\x1b[H"
        start = file_first_line[fi]
        end = (fi < n_files) ? file_first_line[fi+1] - 1 : n_lines
        for (li = start; li <= end; li++) {
            buf = line_buffer[li]
            while ((p = index(buf, "\x01")) > 0) {
                rest = substr(buf, p + 1)
                q = index(rest, "\x02")
                pane_out = pane_out substr(buf, 1, p - 1) rendered_by_idx[substr(rest, 1, q - 1) + 0]
                buf = substr(rest, q + 1)
            }
            pane_out = pane_out buf
        }
        printf "%s", pane_out > out
        close(out)
    }

    printf "%s", hint_lookup
}
