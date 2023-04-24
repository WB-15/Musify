import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musify/API/musify.dart';
import 'package:musify/services/data_manager.dart';
import 'package:musify/services/settings_manager.dart';
import 'package:musify/utilities/mediaitem.dart';
import 'package:rxdart/rxdart.dart';

Stream<PositionData> get positionDataStream =>
    Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
      audioPlayer.positionStream,
      audioPlayer.bufferedPositionStream,
      audioPlayer.durationStream,
      (position, bufferedPosition, duration) =>
          PositionData(position, bufferedPosition, duration ?? Duration.zero),
    );

late AudioHandler audioHandler;

final _loudnessEnhancer = AndroidLoudnessEnhancer();

AudioPlayer audioPlayer = AudioPlayer(
  audioPipeline: AudioPipeline(
    androidAudioEffects: [
      _loudnessEnhancer,
    ],
  ),
);

final playerState = ValueNotifier<PlayerState>(audioPlayer.playerState);

final _playlist = ConcatenatingAudioSource(children: []);

bool get hasNext => activePlaylist['list'].isEmpty
    ? audioPlayer.hasNext
    : id + 1 <= activePlaylist['list'].length;

bool get hasPrevious =>
    activePlaylist['list'].isEmpty ? audioPlayer.hasPrevious : id - 1 >= 0;

Future<void> playSong(Map song) async {
  final songUrl = song['ytid'].length == 0
      ? song['songUrl'].toString()
      : await getSong(song['ytid'], song['isLive']);

  try {
    await checkIfSponsorBlockIsAvailable(song, songUrl);
    await audioPlayer.play();
  } catch (e) {
    debugPrint('Error playing song: $e');
  }
}

Future playNext() async {
  if (activePlaylist.isEmpty || id + 1 >= activePlaylist['list'].length)
    await audioPlayer.seekToNext();
  else {
    await playSong(activePlaylist['list'][id + 1]);
    id = id + 1;
  }
}

Future playPrevious() async {
  if (activePlaylist.isEmpty || id - 1 <= activePlaylist['list'].length)
    await audioPlayer.seekToPrevious();
  else {
    await playSong(activePlaylist['list'][id - 1]);
    id = id - 1;
  }
}

Future<void> checkIfSponsorBlockIsAvailable(song, songUrl) async {
  final _audioSource = AudioSource.uri(
    Uri.parse(songUrl),
    tag: mapToMediaItem(song, songUrl),
  );
  if (sponsorBlockSupport.value && song['ytid'].length != 0) {
    final segments = await getSkipSegments(song['ytid']);
    if (segments.isNotEmpty) {
      if (segments.length == 1) {
        await audioPlayer.setAudioSource(
          ClippingAudioSource(
            child: _audioSource,
            start: Duration(seconds: segments[0]['end']!),
            tag: _audioSource.tag,
          ),
        );
        return;
      } else {
        await audioPlayer.setAudioSource(
          ClippingAudioSource(
            child: _audioSource,
            start: Duration(seconds: segments[0]['end']!),
            end: Duration(seconds: segments[1]['start']!),
            tag: _audioSource.tag,
          ),
        );
        return;
      }
    }
  }
  await audioPlayer.setAudioSource(_audioSource);
}

void changeSponsorBlockStatus() {
  if (sponsorBlockSupport.value == false) {
    sponsorBlockSupport.value = true;
    addOrUpdateData('settings', 'sponsorBlockSupport', true);
  } else {
    sponsorBlockSupport.value = false;
    addOrUpdateData('settings', 'sponsorBlockSupport', false);
  }
}

Future changeShuffleStatus() async {
  await audioPlayer.setShuffleModeEnabled(!shuffleNotifier.value);
  shuffleNotifier.value = !shuffleNotifier.value;
}

void changeAutoPlayNextStatus() {
  playNextSongAutomatically.value = !playNextSongAutomatically.value;
  addOrUpdateData(
    'settings',
    'playNextSongAutomatically',
    playNextSongAutomatically.value,
  );
}

Future changeLoopStatus() async {
  repeatNotifier.value = !repeatNotifier.value;
  await audioPlayer
      .setLoopMode(repeatNotifier.value ? LoopMode.one : LoopMode.off);
}

Future enableBooster() async {
  await _loudnessEnhancer.setEnabled(true);
  await _loudnessEnhancer.setTargetGain(1);
}

Future mute() async {
  await audioPlayer.setVolume(audioPlayer.volume == 0 ? 1 : 0);
  muteNotifier.value = audioPlayer.volume == 0;
}

Future<void> setNewPlaylist() async {
  try {
    await audioPlayer.setAudioSource(_playlist);
  } catch (e) {
    debugPrint('Error: $e');
  }
}

Future<void> addSongs(List<AudioSource> songs) async {
  await _playlist.addAll(songs);
}

class PositionData {
  PositionData(this.position, this.bufferedPosition, this.duration);
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
}

void activateListeners() {
  audioPlayer.playerStateStream.listen((state) async {
    playerState.value = state;
    if (state.processingState == ProcessingState.completed) {
      await audioPlayer.pause();
      await audioPlayer.seek(audioPlayer.duration);
      if (!hasNext) {
        await audioPlayer.seek(Duration.zero);
      } else if (hasNext) {
        await playNext();
      }
    }
  });

  audioPlayer.positionStream.listen((p) async {
    final durationIsNotNull = audioPlayer.duration != null;
    if (durationIsNotNull && p.inSeconds == audioPlayer.duration!.inSeconds) {
      if (!hasNext && playNextSongAutomatically.value) {
        final randomSong = await getRandomSong();
        await playSong(randomSong);
      }
    }
  });
}
