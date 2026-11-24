// GENERATED CODE — hand-maintained to match session.dart.
// If you edit Session, either update this file by hand or run:
//   dart run build_runner build --delete-conflicting-outputs
part of 'session.dart';

// ignore_for_file: type=lint

class SessionAdapter extends TypeAdapter<Session> {
  @override
  final int typeId = 1;

  @override
  Session read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      final key = reader.readByte();
      fields[key] = reader.read();
    }
    return Session(
      id: fields[0] as String,
      appName: fields[1] as String,
      packageName: fields[2] as String,
      startTime: fields[3] as DateTime,
      endTime: fields[4] as DateTime,
      fpsSamples: _doubleList(fields[5]),
      cpuTempSamples: _doubleList(fields[6]),
      gpuTempSamples: _doubleList(fields[7]),
      freeRamSamples: _doubleList(fields[8]),
      cpuUsageSamples: _doubleList(fields[9]),
      gpuUsageSamples: _doubleList(fields[10]),
      storageSpeedSamples: _doubleList(fields[11]),
      batteryDropPercent: (fields[12] as num?)?.toDouble() ?? 0.0,
      lowFpsSamples: fields[13] == null ? null : _doubleList(fields[13]),
      frameTimeHist: fields[14] == null ? null : _intList(fields[14]),
      realFrameData: fields[15] as bool?,
      fpsStartPoll: (fields[16] as num?)?.toInt(),
      batteryCurrentSamples:
          fields[17] == null ? null : _doubleList(fields[17]),
      powerWattsSamples: fields[18] == null ? null : _doubleList(fields[18]),
      deviceModel: fields[19] as String?,
      socName: fields[20] as String?,
      totalRamMb: (fields[21] as num?)?.toDouble(),
      excludedSamples: (fields[22] as num?)?.toInt(),
      pausedSeconds: (fields[23] as num?)?.toInt(),
      stabilitySamples:
          fields[24] == null ? null : _doubleList(fields[24]),
      frameCountSamples:
          fields[25] == null ? null : _intList(fields[25]),
    );
  }

  @override
  void write(BinaryWriter writer, Session obj) {
    writer
      ..writeByte(26)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.appName)
      ..writeByte(2)
      ..write(obj.packageName)
      ..writeByte(3)
      ..write(obj.startTime)
      ..writeByte(4)
      ..write(obj.endTime)
      ..writeByte(5)
      ..write(obj.fpsSamples)
      ..writeByte(6)
      ..write(obj.cpuTempSamples)
      ..writeByte(7)
      ..write(obj.gpuTempSamples)
      ..writeByte(8)
      ..write(obj.freeRamSamples)
      ..writeByte(9)
      ..write(obj.cpuUsageSamples)
      ..writeByte(10)
      ..write(obj.gpuUsageSamples)
      ..writeByte(11)
      ..write(obj.storageSpeedSamples)
      ..writeByte(12)
      ..write(obj.batteryDropPercent)
      ..writeByte(13)
      ..write(obj.lowFpsSamples)
      ..writeByte(14)
      ..write(obj.frameTimeHist)
      ..writeByte(15)
      ..write(obj.realFrameData)
      ..writeByte(16)
      ..write(obj.fpsStartPoll)
      ..writeByte(17)
      ..write(obj.batteryCurrentSamples)
      ..writeByte(18)
      ..write(obj.powerWattsSamples)
      ..writeByte(19)
      ..write(obj.deviceModel)
      ..writeByte(20)
      ..write(obj.socName)
      ..writeByte(21)
      ..write(obj.totalRamMb)
      ..writeByte(22)
      ..write(obj.excludedSamples)
      ..writeByte(23)
      ..write(obj.pausedSeconds)
      ..writeByte(24)
      ..write(obj.stabilitySamples)
      ..writeByte(25)
      ..write(obj.frameCountSamples);
  }

  static List<double> _doubleList(dynamic v) {
    if (v == null) return <double>[];
    return (v as List).map((e) => (e as num).toDouble()).toList();
  }

  static List<int> _intList(dynamic v) {
    if (v == null) return <int>[];
    return (v as List).map((e) => (e as num).toInt()).toList();
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionAdapter && runtimeType == other.runtimeType && typeId == other.typeId;
}
