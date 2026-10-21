"""Self-check for select_tracks(): run directly, no pytest needed.

    python3 webhook-server/test_track_trim.py
"""
from server import select_tracks


def audio(lang):
    return {'codec_type': 'audio', 'tags': {'language': lang}}


def sub(lang, forced=False):
    return {'codec_type': 'subtitle', 'tags': {'language': lang}, 'disposition': {'forced': int(forced)}}


def test_keeps_original_plus_eng_fre():
    tracks = [audio('ita'), audio('eng'), audio('fre'), audio('spa')]
    kept, _ = select_tracks(tracks, [], original_code='ita')
    assert {s['tags']['language'] for s in kept} == {'ita', 'eng', 'fre'}


def test_no_duplicate_when_original_is_english():
    tracks = [audio('eng'), audio('fre'), audio('ita')]
    kept, _ = select_tracks(tracks, [], original_code='eng')
    assert {s['tags']['language'] for s in kept} == {'eng', 'fre'}


def test_subs_keep_eng_fre_and_forced_regardless_of_language():
    subs = [sub('eng'), sub('fre'), sub('ita'), sub('ita', forced=True), sub('spa')]
    _, kept = select_tracks([], subs, original_code='ita')
    assert len(kept) == 3  # eng, fre, the forced ita one


def test_fra_and_fr_tags_count_as_french():
    tracks = [audio('fra'), audio('fr'), audio('ita')]
    kept, _ = select_tracks(tracks, [], original_code='ita')
    assert len(kept) == 3  # fra + fr (both = french) + ita (original)


def test_safety_net_keeps_everything_if_nothing_matches():
    # unmapped original language (e.g. Radarr says "Original"): no audio would match at all
    tracks = [audio('jpn'), audio('kor')]
    kept, _ = select_tracks(tracks, [], original_code=None)
    assert kept == tracks  # never strip down to zero audio tracks


def test_safety_net_keeps_subs_if_filter_empties_them():
    subs = [sub('ita'), sub('spa')]  # no eng/fre/forced at all
    _, kept = select_tracks([], subs, original_code='ita')
    assert kept == subs


def test_already_clean_keeps_same_count():
    tracks = [audio('eng'), audio('fre')]
    kept, _ = select_tracks(tracks, [], original_code='eng')
    assert len(kept) == len(tracks)


if __name__ == '__main__':
    import sys
    tests = [v for k, v in list(globals().items()) if k.startswith('test_')]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"\n{len(tests)} tests passed")
