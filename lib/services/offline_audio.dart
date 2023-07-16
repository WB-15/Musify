import 'package:on_audio_query/on_audio_query.dart' hide context;

final OnAudioQuery audioQuery = OnAudioQuery();

AudioSortType _sortBy = AudioSortType.DATE_ADDED;

void upadateSortType(AudioSortType sort) => _sortBy = sort;

Future<List<AudioModel>> getMusic({
  String? searchQuery,
  AudioSortType? sortBy,
}) async {
  final allSongs = await audioQuery.querySongs(
    filter: MediaFilter.forSongs(
      audioSortType: sortBy ?? _sortBy,
    ),
  );

  if (searchQuery != null && searchQuery.isNotEmpty) {
    return allSongs
        .where(
          (song) => song.displayName
              .toLowerCase()
              .contains(searchQuery.toLowerCase()),
        )
        .toList();
  } else {
    return allSongs.toList();
  }
}

Future<List<ArtistModel>> getRandomArtists() async {
  final _artists = await audioQuery.queryArtists();
  final randomArtists = _artists.toList()..shuffle();
  return randomArtists.take(10).toList();
}
