import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musify/services/audio_manager.dart';

class MyAudioHandler extends BaseAudioHandler {
  final ConcatenatingAudioSource _playlist =
      ConcatenatingAudioSource(children: []);

  MyAudioHandler() {
    _loadEmptyPlaylist();
    _notifyAudioHandlerAboutPlaybackEvents();
    _listenForDurationChanges();
    _listenForCurrentSongIndexChanges();
    _listenForSequenceStateChanges();
  }

  Future<void> _loadEmptyPlaylist() async {
    try {
      await audioPlayer!.setAudioSource(_playlist);
    } catch (e) {
      debugPrint('Error: $e');
    }
  }

  void _notifyAudioHandlerAboutPlaybackEvents() {
    audioPlayer!.playbackEventStream.listen((PlaybackEvent event) {
      final bool playing = audioPlayer!.playing;
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            MediaControl.skipToPrevious,
            if (playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
            MediaControl.stop
          ],
          systemActions: const {
            MediaAction.seek,
          },
          androidCompactActionIndices: const [0, 1, 3],
          processingState: const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[audioPlayer!.processingState]!,
          repeatMode: const {
            LoopMode.off: AudioServiceRepeatMode.none,
            LoopMode.one: AudioServiceRepeatMode.one,
            LoopMode.all: AudioServiceRepeatMode.all,
          }[audioPlayer!.loopMode]!,
          shuffleMode: (audioPlayer!.shuffleModeEnabled)
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none,
          playing: playing,
          updatePosition: audioPlayer!.position,
          bufferedPosition: audioPlayer!.bufferedPosition,
          speed: audioPlayer!.speed,
          queueIndex: event.currentIndex,
        ),
      );
    });
  }

  void _listenForDurationChanges() {
    audioPlayer!.durationStream.listen((duration) {
      var index = audioPlayer!.currentIndex;
      final List<MediaItem> newQueue = queue.value;
      if (index == null || newQueue.isEmpty) return;
      if (audioPlayer!.shuffleModeEnabled) {
        index = audioPlayer!.shuffleIndices![index];
      }
      final MediaItem oldMediaItem = newQueue[index];
      final MediaItem newMediaItem = oldMediaItem.copyWith(duration: duration);
      newQueue[index] = newMediaItem;
      queue.add(newQueue);
      mediaItem.add(newMediaItem);
    });
  }

  void _listenForCurrentSongIndexChanges() {
    audioPlayer!.currentIndexStream.listen((index) {
      final List<MediaItem> playlist = queue.value;
      if (index == null || playlist.isEmpty) return;
      if (audioPlayer!.shuffleModeEnabled) {
        index = audioPlayer!.shuffleIndices![index];
      }
      mediaItem.add(playlist[index]);
    });
  }

  void _listenForSequenceStateChanges() {
    audioPlayer!.sequenceStateStream.listen((SequenceState? sequenceState) {
      final sequence = sequenceState?.effectiveSequence;
      if (sequence == null || sequence.isEmpty) return;
      final items = sequence.map((source) => source.tag as MediaItem);
      queue.add(items.toList());
      shuffleNotifier.value = sequenceState!.shuffleModeEnabled;
    });
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    final audioSource = mediaItems.map(_createAudioSource);
    await _playlist.addAll(audioSource.toList());

    final newQueue = queue.value..addAll(mediaItems);
    queue.add(newQueue);
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final audioSource = _createAudioSource(mediaItem);
    await _playlist.add(audioSource);

    final newQueue = queue.value..add(mediaItem);
    queue.add(newQueue);
  }

  UriAudioSource _createAudioSource(MediaItem mediaItem) {
    return AudioSource.uri(
      Uri.parse(mediaItem.extras!['url'].toString()),
      tag: mediaItem,
    );
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    await _playlist.removeAt(index);

    final newQueue = queue.value..removeAt(index);
    queue.add(newQueue);
  }

  @override
  Future<void> play() => audioPlayer!.play();

  @override
  Future<void> pause() => audioPlayer!.pause();

  @override
  Future<void> seek(Duration position) => audioPlayer!.seek(position);

  @override
  Future<void> skipToQueueItem(int index) async {
    late int ind;
    if (index < 0 || index >= queue.value.length) return;
    if (audioPlayer!.shuffleModeEnabled) {
      ind = audioPlayer!.shuffleIndices![index];
    }
    await audioPlayer!.seek(Duration.zero, index: ind);
  }

  @override
  Future<void> skipToNext() => audioPlayer!.seekToNext();

  @override
  Future<void> skipToPrevious() => audioPlayer!.seekToPrevious();

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        await audioPlayer!.setLoopMode(LoopMode.off);
        break;
      case AudioServiceRepeatMode.one:
        await audioPlayer!.setLoopMode(LoopMode.one);
        break;
      case AudioServiceRepeatMode.group:
      case AudioServiceRepeatMode.all:
        await audioPlayer!.setLoopMode(LoopMode.all);
        break;
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (shuffleMode == AudioServiceShuffleMode.none) {
      await audioPlayer!.setShuffleModeEnabled(false);
    } else {
      await audioPlayer!.shuffle();
      await audioPlayer!.setShuffleModeEnabled(true);
    }
  }

  @override
  Future customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'dispose') {
      await audioPlayer!.dispose();
      await super.stop();
    }
  }

  @override
  Future<void> stop() async {
    await audioPlayer!.stop();
    return super.stop();
  }
}
