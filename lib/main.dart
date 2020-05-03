import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:interactive_webview/interactive_webview.dart';

import 'package:nfsee/data/blocs/bloc.dart';
import 'package:nfsee/data/blocs/provider.dart';
import 'package:nfsee/data/card.dart';
import 'package:nfsee/data/database/database.dart';
import 'package:nfsee/generated/l10n.dart';
import 'package:nfsee/models.dart';
import 'package:nfsee/ui/card_physics.dart';
import 'package:nfsee/ui/home.dart';
import 'package:nfsee/utilities.dart';
import 'package:nfsee/ui/card_detail.dart';
import 'package:nfsee/ui/scripts.dart';
import 'package:nfsee/ui/settings.dart';
import 'package:nfsee/ui/widgets.dart';

void main() => runApp(NFSeeApp());

class NFSeeApp extends StatefulWidget {
  @override
  _NFSeeAppState createState() => _NFSeeAppState();
}

class _NFSeeAppState extends State<NFSeeApp> {
  NFSeeAppBloc bloc;

  @override
  void initState() {
    bloc = NFSeeAppBloc();
    super.initState();
  }

  @override
  Widget build(context) {
    return BlocProvider(
      bloc: bloc,
      // Either Material or Cupertino widgets work in either Material or Cupertino
      // Apps.
      child: MaterialApp(
        localizationsDelegates: [
          S.delegate,
          GlobalMaterialLocalizations.delegate,
        ],
        supportedLocales: S.delegate.supportedLocales,
        onGenerateTitle: (context) {
          return S.of(context).homeScreenTitle;
        },
        theme: ThemeData(
          brightness: Brightness.light,
          primarySwatch: Colors.orange,
          accentColor: Colors.deepOrange,
        ),
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          primarySwatch: Colors.orange,
          accentColor: Colors.deepOrange,
        ),
        builder: (context, child) {
          return CupertinoTheme(
            data: CupertinoThemeData(),
            child: Material(child: child),
          );
        },
        home: PlatformAdaptingHomePage(),
      ),
    );
  }
}

// Shows a different type of scaffold depending on the platform.
//
// This file has the most amount of non-sharable code since it behaves the most
// differently between the platforms.
//
// These differences are also subjective and have more than one 'right' answer
// depending on the app and content.
class PlatformAdaptingHomePage extends StatefulWidget {
  @override
  _PlatformAdaptingHomePageState createState() =>
      _PlatformAdaptingHomePageState();
}

class _PlatformAdaptingHomePageState extends State<PlatformAdaptingHomePage> {
  final _webView = InteractiveWebView();
  StreamSubscription _webViewListener;
  var _reading = false;
  Exception error;
  final GlobalKey<ScaffoldState> _scaffoldKey = new GlobalKey<ScaffoldState>();

  PageController topController;
  int currentTop = 1;

  NFSeeAppBloc get bloc => BlocProvider.provideBloc(context);

  @override
  void initState() {
    super.initState();
    this._initSelf();
  }

  @override
  void reassemble() {
    this._initSelf();
    super.reassemble();
  }

  void _initSelf() {
    this._addWebViewHandler();
    topController = PageController();
  }

  @override
  void dispose() {
    _webViewListener.cancel();
    super.dispose();
  }

  void _addWebViewHandler() async {
    _webView.evalJavascript(await rootBundle.loadString('assets/ber-tlv.js'));
    _webView.evalJavascript(await rootBundle.loadString('assets/crypto-js.js'));
    _webView.evalJavascript(await rootBundle.loadString('assets/crypto.js'));
    _webView.evalJavascript(await rootBundle.loadString('assets/reader.js'));
    _webView.evalJavascript(await rootBundle.loadString('assets/codes.js'));
    _webViewListener = _webView.didReceiveMessage.listen(_onReceivedMessage);
  }

  void showSnackbar(SnackBar snackBar) {
    if (_scaffoldKey.currentState != null) {
      _scaffoldKey.currentState.showSnackBar(snackBar);
    }
  }

  void _onReceivedMessage(WebkitMessage message) async {
    if (webviewOwner != WebViewOwner.Main) {
      return;
    }
    var scriptModel = ScriptDataModel.fromJson(message.data);
    log('Received action ${scriptModel.action} from script');
    switch (scriptModel.action) {
      case 'poll':
        error = null;
        try {
          final tag = await FlutterNfcKit.poll(iosAlertMessage: S.of(context).waitForCard);
          _webView.evalJavascript("pollCallback(${jsonEncode(tag)})");
          FlutterNfcKit.setIosAlertMessage(S.of(context).cardPolled);
        } on PlatformException catch (e) {
          error = e;
          // no need to do anything with FlutterNfcKit, which will reset itself
          log('Transceive error: ${e.toDetailString()}');
          _closeReadModal(this.context);
          showSnackbar(SnackBar(
              content:
                  Text('${S.of(context).readFailed}: ${e.toDetailString()}')));
          // reject the promise
          _webView.evalJavascript("pollErrorCallback(${e.toJsonString()})");
        }
        break;

      case 'transceive':
        try {
          final rapdu = await FlutterNfcKit.transceive(scriptModel.data);
          _webView.evalJavascript("transceiveCallback('$rapdu')");
        } on PlatformException catch (e) {
          error = e;
          // we need to explicitly finish the reader session now **in the script** to stop any following operations,
          // otherwise a following poll might crash the entire application,
          // because ReaderMode is still enabled, and the obselete MethodChannel.Result will be re-used.
          log('Transceive error: ${e.toDetailString()}');
          _closeReadModal(this.context);
          showSnackbar(SnackBar(
              content:
                  Text('${S.of(context).readFailed}: ${e.toDetailString()}')));
          _webView
              .evalJavascript("transceiveErrorCallback(${e.toJsonString()})");
        }
        break;

      case 'report':
        _closeReadModal(this.context);
        final id = await bloc.addDumpedRecord(jsonEncode(scriptModel.data));
        this._navigateToTag(DumpedRecord(
          id: id,
          time: DateTime.now(),
          data: jsonEncode(scriptModel.data),
          config: DEFAULT_CONFIG,
        ));
        break;

      case 'finish':
        if (error != null) {
          await FlutterNfcKit.finish(iosErrorMessage: S.of(context).readFailed);
          error = null;
        } else {
          await FlutterNfcKit.finish(iosAlertMessage: S.of(context).readSucceeded);
        }
        break;

      case 'log':
        log('Log from script: ${scriptModel.data.toString()}');
        break;

      default:
        assert(false, 'Unknown action ${scriptModel.action}');
        break;
    }
  }

  void _navigateToScriptMode() {
    webviewOwner = WebViewOwner.Script;
    Navigator.push(
            context, MaterialPageRoute(builder: (context) => ScriptsAct()))
        .then((_) {
      webviewOwner = WebViewOwner.Main;
    });
  }

  void _navigateToTag(DumpedRecord record) {
    return; // TODO: move to homepage

    var data = jsonDecode(record.data);
    var config = jsonDecode(record.config ?? DEFAULT_CONFIG);

    // convert card_type to Type CardType
    data['card_type'] =
        getEnumFromString<CardType>(CardType.values, data['card_type']);

    log(data.toString());
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (context) => CardDetailTab(
                data: data, config: config, id: record.id, time: record.time),
          ),
        );
        break;
      case TargetPlatform.iOS:
        Navigator.of(context).push<void>(
          CupertinoPageRoute(
            title: 'Card Detail',
            builder: (context) => CardDetailTab(
                data: data, config: config, id: record.id, time: record.time),
          ),
        );
        break;
      default:
        assert(false, 'Unexpected platform $defaultTargetPlatform');
    }
  }

  Widget _buildHomePageAndroid(BuildContext context) {
    final bottom = BottomNavigationBar(
      currentIndex: this.currentTop,
      onTap: (e) {
        setState(() {
          this.currentTop = e;
          this.topController.animateToPage(e, duration: Duration(milliseconds: 500), curve: Curves.ease);
        });
      },
      items: <BottomNavigationBarItem>[
        BottomNavigationBarItem(
          icon: Icon(Icons.code),
          title: Text('脚本'),
        ),

        BottomNavigationBarItem(
          icon: Icon(Icons.nfc),
          title: Text('扫描'),
        ),

        BottomNavigationBarItem(
          icon: Icon(Icons.settings),
          title: Text('设置'),
        ),
      ],
    );

    final top = this._buildTop(context);

    return Container(child: Column(
      children: <Widget>[top, bottom],
    ));

  }

  Widget _buildTop(context) {
    final scripts = ScriptsAct();
    final home = Home();
    final settings = SettingsAct();
    return Expanded(
      child: PageView(
        controller: topController,
        children: <Widget>[scripts, home, settings],
        onPageChanged: (page) {
          this.setState(() { this.currentTop = page; });
        },
      )
    );
  }

  Widget _buildHistoryPageIos(BuildContext context) {
    return CustomScrollView(
      slivers: <Widget>[
        CupertinoSliverNavigationBar(
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CupertinoButton(
                padding: EdgeInsets.zero,
                child: Icon(CupertinoIcons.delete),
                onPressed: () {
                  _deleteAll(context);
                },
              ),
              CupertinoButton(
                padding: EdgeInsets.zero,
                child: Icon(CupertinoIcons.plus_circled),
                onPressed: () {
                  _readTag(context);
                },
              )
            ],
          ),
        ),
        SliverPadding(
          padding: MediaQuery.of(context)
              .removePadding(
                  removeTop: true, removeLeft: true, removeRight: true)
              .padding,
          sliver: StreamBuilder<List<DumpedRecord>>(
            stream: bloc.dumpedRecords,
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data.length == 0) {
                return SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    return Text(
                      "Press button on the top right to scan a NFC tag",
                      style: TextStyle(color: Colors.grey),
                      textAlign: TextAlign.center,
                    );
                  }, childCount: 1),
                );
              }
              final records = snapshot.data.reversed.toList();
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    int realIndex = index ~/ 2;
                    if (index.isEven) {
                      return ReportRowItem(
                          record: records[realIndex],
                          onTap: () {
                            this._navigateToTag(records[realIndex]);
                          });
                    } else {
                      return Divider(
                        height: 0,
                        color: Colors.grey,
                        indent: 10,
                        endIndent: 10,
                      );
                    }
                  },
                  childCount: math.max(1, 2 * records.length - 1),
                ),
              );
            },
          ),
        )
      ],
    );
  }

  Widget _buildHomePageIos(BuildContext context) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        items: [
          BottomNavigationBarItem(
            title: Text(S.of(context).scanTabTitle),
            icon: Icon(Icons.nfc),
          ),
          BottomNavigationBarItem(
            title: Text(S.of(context).scriptTabTitle),
            icon: Icon(Icons.play_arrow),
          ),
          BottomNavigationBarItem(
            title: Text(S.of(context).settingsTabTitle),
            icon: Icon(Icons.settings),
          ),
        ],
        onTap: (index) {
          switch (index) {
            case 0:
              webviewOwner = WebViewOwner.Main;
              break;
            case 1:
              webviewOwner = WebViewOwner.Script;
              break;
            case 2:
              break;
            default:
              assert(false, 'Unexpected tab');
          }
        },
      ),
      tabBuilder: (context, index) {
        switch (index) {
          case 0:
            return CupertinoTabView(
              builder: (context) => _buildHistoryPageIos(context),
              defaultTitle: S.of(context).homeScreenTitle,
            );
          case 1:
            return CupertinoTabView(
              builder: (context) => ScriptsAct(),
              defaultTitle: S.of(context).scriptTabTitle,
            );
          case 2:
            return CupertinoTabView(
              builder: (context) => SettingsAct(),
              defaultTitle: S.of(context).settingsTabTitle,
            );
          default:
            assert(false, 'Unexpected tab');
            return null;
        }
      },
    );
  }

  @override
  Widget build(context) {
    return PlatformWidget(
      androidBuilder: _buildHomePageAndroid,
      iosBuilder: _buildHomePageIos,
    );
  }

  Future<void> _readTag(BuildContext context) async {
    // Because we are launching an modal bottom sheet, user should not be able to intereact with the app anymore
    assert(!_reading);

    _reading = true;
    var modal;
    if (defaultTargetPlatform == TargetPlatform.android) {
      modal = showModalBottomSheet(
        context: context,
        builder: this._buildReadModal,
      );
    } else {
      modal = Future.value(true);
    }

    final script = await rootBundle.loadString('assets/read.js');
    _webView.evalJavascript(script);
    // this._mockRead();

    if ((await modal) != true) {
      // closed by user, reject the promise
      _webView.evalJavascript("pollErrorCallback('User cancelled operation')");
    }

    _reading = false;
  }

  void _deleteAll(BuildContext context) {
    bloc.delAllDumpedRecord();
  }

  void _closeReadModal(BuildContext context) {
    if (_reading && defaultTargetPlatform != TargetPlatform.iOS) {
      Navigator.of(context).pop(true);
    }
  }

  Widget _buildReadModal(BuildContext context) {
    return Container(
        child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  S.of(context).waitForCard,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18),
                ),
                SizedBox(height: 10),
                Image.asset('assets/read.webp', height: 200),
              ],
            )));
  }
}
