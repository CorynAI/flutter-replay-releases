package ai.coryn.replay.flutter

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware

/** Flutter's entry point for the plugin; the implementation ships obfuscated in the Coryn Android SDK module `ai.coryn.replay.internal:flutter`. **/
public class CorynReplayPlugin private constructor(plugin: CorynFlutterPlugin) : FlutterPlugin by plugin, ActivityAware by plugin {
    public constructor() : this(CorynFlutterPlugin())
}
