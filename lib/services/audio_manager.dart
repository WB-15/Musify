import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musify/API/musify.dart';
import 'package:musify/services/data_manager.dart';
import 'package:musify/services/logger_service.dart';
import 'package:musify/services/offline_audio.dart';
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
final Random _random = Random();

bool get currentModeIsLocal {
  final tag = audioPlayer.sequenceState?.currentSource?.tag;
  return tag?.extras?['localSongId'] is int;
}

bool get hasNext {
  if (activePlaylist['list'].isEmpty) {
    return audioPlayer.hasNext;
  }
  return id + 1 < activePlaylist['list'].length;
}

bool get hasPrevious {
  if (activePlaylist['list'].isEmpty) {
    return audioPlayer.hasPrevious;
  }
  return id > 0;
}

Future<void> playSong(Map song) async {
  try {
    final songUrl = await getSong(song['ytid'], song['isLive']);
    await checkIfSponsorBlockIsAvailable(song, songUrl);
    await audioPlayer.play();
  } catch (e) {
    Logger.log('Error playing song: $e');
  }
}

Future<void> playLocalSong(int index) async {
  if (!currentModeIsLocal) {
    await _playlist.clear();
    await moveAudiosToQueue();
    await setNewPlaylist();
  }

  if (index < 0 || index >= _playlist.children.length) return;

  await audioHandler.skipToQueueItem(index);

  await audioPlayer.play();
}

Future<void> playNext() async {
  if (currentModeIsLocal) {
    await audioPlayer.seekToNext();
  } else {
    if (shuffleNotifier.value) {
      final randomIndex = _generateRandomIndex(activePlaylist['list'].length);
      id = randomIndex;
      await playSong(activePlaylist['list'][id]);
    } else {
      id++;
      await playSong(activePlaylist['list'][id]);
    }
  }
}

Future<void> playPrevious() async {
  if (currentModeIsLocal) {
    await audioPlayer.seekToPrevious();
  } else {
    if (shuffleNotifier.value) {
      final randomIndex = _generateRandomIndex(activePlaylist['list'].length);

      id = randomIndex;
      await playSong(activePlaylist['list'][id]);
    } else {
      id--;
      await playSong(activePlaylist['list'][id]);
    }
  }
}

int _generateRandomIndex(int length) {
  var randomIndex = _random.nextInt(length);

  while (randomIndex == id) {
    randomIndex = _random.nextInt(length);
  }

  return randomIndex;
}

Future<void> checkIfSponsorBlockIsAvailable(song, songUrl) async {
  final _audioSource = AudioSource.uri(
    Uri.parse(songUrl),
    tag: mapToMediaItem(song, songUrl),
  );
  if (sponsorBlockSupport.value) {
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
  sponsorBlockSupport.value = !sponsorBlockSupport.value;
  addOrUpdateData('settings', 'sponsorBlockSupport', sponsorBlockSupport.value);
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
  await _loudnessEnhancer.setTargetGain(0.5);
}

Future mute() async {
  await audioPlayer.setVolume(audioPlayer.volume == 0 ? 1 : 0);
  muteNotifier.value = audioPlayer.volume == 0;
}

Future<void> setNewPlaylist() async {
  try {
    await audioPlayer.setAudioSource(_playlist);
  } catch (e) {
    Logger.log('Error in setNewPlaylist: $e');
  }
}

Future<void> addSongs(List<AudioSource> songs) async {
  try {
    await _playlist.addAll(songs);
  } catch (e) {
    Logger.log('Error adding songs to the playlist: $e');
  }
}

class PositionData {
  PositionData(this.position, this.bufferedPosition, this.duration);
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
}

bool _isPlaybackComplete = false;
bool _isAudioFinished = false;

void activateListeners() {
  audioPlayer.playerStateStream.listen((state) {
    playerState.value = state;

    if (state.processingState == ProcessingState.completed) {
      if (!_isPlaybackComplete) {
        _isPlaybackComplete = true;
        audioPlayer.pause();
        audioPlayer.seek(audioPlayer.duration);

        if (!hasNext) {
          audioPlayer.seek(Duration.zero);
        } else {
          playNext();
        }
      }
    } else {
      _isPlaybackComplete = false;
    }
  });

  audioPlayer.positionStream.listen((p) async {
    if (!_isAudioFinished &&
        audioPlayer.duration != null &&
        p.inSeconds == audioPlayer.duration!.inSeconds) {
      _isAudioFinished = true;

      if (!hasNext && playNextSongAutomatically.value) {
        final randomSong = await getRandomSong();
        await playSong(randomSong).then(
          (v) => {_isAudioFinished = false},
        );
      }
    }
  });
}
