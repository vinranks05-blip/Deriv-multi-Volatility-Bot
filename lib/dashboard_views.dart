part of 'main.dart';

extension _DashboardViews on _DashboardState {
  List<Market> _visibleMarkets() {
    final list = markets
        .where((m) => !readyOnly || (m.live && m.ticks.length >= 250))
        .toList();
    list.sort((a, b) {
      final pin = (pinned.contains(b.symbol) ? 1 : 0) -
          (pinned.contains(a.symbol) ? 1 : 0);
      return pin != 0 ? pin : markets.indexOf(a).compareTo(markets.indexOf(b));
    });
    return list;
  }

  void _applyPaper({bool start = false}) {
    try {
      final next = PaperConfig(
          stake: double.parse(stakeInput.text),
          grossMultiplier: double.parse(payoutInput.text),
          delayMs: int.parse(delayInput.text),
          durationTicks: int.parse(durationInput.text),
          expiryMs: int.parse(expiryInput.text),
          condition: modeLabel,
          symbol: selected);
      next.validate();
      if (!ledgerReady) throw StateError('Wait for the ledger to load');
      _refresh(() {
        ledger.config = next;
        if (start) ledger.enabled = true;
      });
      _save();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(start
              ? 'Paper trading started'
              : 'Assumptions saved for $selected • $modeLabel')));
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid paper settings: $error')));
    }
  }

  Widget _paperInput(TextEditingController controller, String label) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder())));

  Widget _paperDashboard() {
    final stats = LedgerStats(ledger.records.values);
    final unresolved =
        ledger.records.values.where((r) => r.paper == 'unresolved').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Paper Trading',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
      const Text('Simulation only • no account connection or broker orders',
          style: TextStyle(color: Colors.amber)),
      const SizedBox(height: 12),
      Row(children: [
        _metric(ledger.available.toStringAsFixed(2), 'AVAILABLE USD'),
        const SizedBox(width: 8),
        _metric(stats.profit.toStringAsFixed(2), 'SIMULATED P/L')
      ]),
      Row(children: [
        _metric(ledger.reserved.toStringAsFixed(2), 'RESERVED USD'),
        const SizedBox(width: 8),
        _metric(stats.drawdown.toStringAsFixed(2), 'MAX REALIZED DRAWDOWN')
      ]),
      Text(
          'Starting balance: ${ledger.initialBalance.toStringAsFixed(2)} USD • ${stats.settled.length} paper outcomes. Drawdown excludes unresolved outcomes.'),
      const SizedBox(height: 12),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _pill(ledger.enabled ? 'PAPER RUNNING' : 'PAPER STOPPED',
              color: ledger.enabled ? green : Colors.orange),
          const Spacer(),
          if (ledger.enabled)
            TextButton(
                onPressed: () {
                  _refresh(() => ledger.stopEntries());
                },
                child: const Text('STOP ENTRIES'))
        ]),
        Text(
            'Configured: ${ledger.config.symbol} • ${ledger.config.condition}'),
        Text(
            'Stake ${ledger.config.stake.toStringAsFixed(2)} • assumed gross return ${ledger.config.grossMultiplier.toStringAsFixed(2)}×'),
        Text(
            'Delay ${ledger.config.delayMs}ms • duration ${ledger.config.durationTicks} subsequent tick(s) • entry window ${ledger.config.expiryMs}ms'),
        Text(
            'Break-even at this assumed payout: ${(100 / ledger.config.grossMultiplier).toStringAsFixed(2)}% paper wins.'),
        const Text(
            'Payouts are user-entered assumptions, not live broker quotes. Model scores are not used as a proven trading edge.',
            style: TextStyle(fontSize: 12, color: Colors.amber)),
        const SizedBox(height: 8),
        const Text(
            'Entry = first received tick after the delay. Exit = N later received ticks. These prices are public-feed observations, not broker executions. One paper trade at a time; stake is reserved until settled.'),
      ])),
      _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Simulation assumptions',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        Text(
            'Apply to $modeLabel. Change the condition on Radar. Other conditions stay in the signal ledger without paper entry.'),
        DropdownButton<String>(
            isExpanded: true,
            value: selected,
            items: markets
                .map((m) =>
                    DropdownMenuItem(value: m.symbol, child: Text(m.name)))
                .toList(),
            onChanged: (v) {
              if (v != null) _refresh(() => selected = v);
            }),
        _paperInput(stakeInput, 'Paper stake (USD)'),
        _paperInput(
            payoutInput, 'Assumed gross return / stake (includes stake)'),
        _paperInput(delayInput, 'Entry delay (milliseconds)'),
        _paperInput(durationInput, 'Duration after entry (ticks, 1–100)'),
        _paperInput(expiryInput, 'Signal entry window (milliseconds)'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              onPressed: ledgerReady ? () => _applyPaper() : null,
              child: const Text('SAVE ASSUMPTIONS')),
          FilledButton(
              onPressed: ledgerReady ? () => _applyPaper(start: true) : null,
              child: const Text('START PAPER')),
        ]),
        const Text(
            'Stopping blocks waiting/new entries; an open paper trade continues while the feed remains available. A feed gap or app pause marks an open trade unresolved and keeps its stake reserved.',
            style: TextStyle(fontSize: 12, color: Colors.white60)),
      ])),
      if (unresolved.isNotEmpty)
        _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Unresolved paper trades',
              style: TextStyle(color: Colors.amber, fontSize: 18)),
          const Text(
              'The missing outcome cannot be reconstructed. You can conservatively book the full stake as a simulated loss to release the reservation.'),
          for (final r in unresolved)
            TextButton(
                onPressed: () {
                  _refresh(
                      () => ledger.resolveUncertainLoss(r.id, DateTime.now()));
                },
                child: Text(
                    'BOOK ${r.symbol} ${r.config.stake.toStringAsFixed(2)} AS FULL LOSS')),
        ])),
      const Text('Recent paper activity',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      ...ledger.records.values
          .where((r) => r.paper != 'skipped')
          .toList()
          .reversed
          .take(20)
          .map(_signalCard),
      const SizedBox(height: 12),
      _performanceTable(),
    ]);
  }

  String _percent(double? value) =>
      value == null ? '—' : '${(100 * value).toStringAsFixed(1)}%';

  Widget _performanceTable() {
    final groups = <String, List<SignalRecord>>{};
    for (final r in ledger.records.values) {
      final configured =
          r.condition == r.config.condition && r.symbol == r.config.symbol;
      final assumptions = configured
          ? '${r.config.durationTicks}t / ${r.config.delayMs}ms • ${r.config.grossMultiplier}× / ${r.config.stake} USD'
          : 'paper not configured';
      final key = '${r.symbol} • ${r.condition} • $assumptions';
      groups.putIfAbsent(key, () => []).add(r);
    }
    return _card(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Performance by setup',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      const Text(
          'Next-tick accuracy and delayed paper outcomes are different measurements. Approximate 95% intervals assume independent observations; shared ticks and overlapping windows weaken that assumption.',
          style: TextStyle(fontSize: 12, color: Colors.white60)),
      if (groups.isEmpty)
        const Padding(
            padding: EdgeInsets.all(12), child: Text('No issued signals yet.')),
      SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
              columns: const [
                DataColumn(
                    label: Text('Market / condition / paper assumptions')),
                DataColumn(label: Text('Issued / scored')),
                DataColumn(label: Text('Next-tick accuracy (95% interval)')),
                DataColumn(label: Text('Uniform reference')),
                DataColumn(label: Text('Paper wins / settled')),
                DataColumn(label: Text('Paper P/L / max drawdown')),
              ],
              rows: groups.entries.map((e) {
                final stats = LedgerStats(e.value),
                    range = LedgerStats(e.value).interval;
                final wins =
                    stats.settled.where((r) => r.paper == 'won').length;
                return DataRow(cells: [
                  DataCell(Text(e.key)),
                  DataCell(
                      Text('${e.value.length} / ${stats.observed.length}')),
                  DataCell(Text(
                      '${_percent(stats.accuracy)}${range == null ? '' : ' (${_percent(range.$1)}–${_percent(range.$2)})'}')),
                  DataCell(Text(_percent(e.value.first.baseline))),
                  DataCell(Text('$wins / ${stats.settled.length}')),
                  DataCell(Text(
                      '${stats.profit.toStringAsFixed(2)} / ${stats.drawdown.toStringAsFixed(2)} USD'))
                ]);
              }).toList())),
    ]));
  }

  Widget _signalCard(SignalRecord r) => _card(ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('${r.symbol} • ${r.label}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(
              'Forecast: ${r.observation} • Paper: ${r.paper}${r.profit == null ? '' : ' • P/L ${r.profit!.toStringAsFixed(2)} USD'}'),
          children: [
            Align(
                alignment: Alignment.centerLeft,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText('ID: ${r.id}'),
                      Text('Issued UTC: ${r.issued.toIso8601String()}'),
                      Text(
                          'Source tick: ${r.sourceEpoch} • sequence ${r.sourceSequence}'),
                      Text(
                          'Model: ${r.model} • score ${r.score.toStringAsFixed(1)}% (uncalibrated)'),
                      Text(
                          'Next-tick digit: ${r.actual ?? '—'} • epoch ${r.observationEpoch ?? '—'}'),
                      Text(
                          'Paper assumptions: ${r.config.stake} USD • ${r.config.grossMultiplier}× gross • ${r.config.delayMs}ms delay • ${r.config.durationTicks} ticks • ${r.config.expiryMs}ms entry window'),
                      Text(
                          'Entry: ${r.entryAt?.toIso8601String() ?? '—'} • tick ${r.entryEpoch ?? '—'} • price ${r.entryPrice ?? '—'}'),
                      Text(
                          'Exit: ${r.exitAt?.toIso8601String() ?? '—'} • tick ${r.exitEpoch ?? '—'} • price ${r.exitPrice ?? '—'} • digit ${r.exitDigit ?? '—'}'),
                      if (r.reason.isNotEmpty)
                        Text(r.reason,
                            style: const TextStyle(color: Colors.amber)),
                    ]))
          ]));

  Widget _filter(String label, String value, List<String> values,
          void Function(String) update) =>
      SizedBox(
          width: 180,
          child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: value,
              decoration: InputDecoration(labelText: label),
              items: values
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: (v) {
                if (v != null)
                  _refresh(() {
                    update(v);
                    historyPage = 0;
                  });
              }));

  Future<void> _exportLedger() async {
    try {
      await storage.flush();
      final csv = ledger.csv();
      final name =
          'signals-${DateTime.now().toUtc().millisecondsSinceEpoch}.csv';
      await SharePlus.instance.share(ShareParams(files: [
        XFile.fromData(Uint8List.fromList(utf8.encode(csv)),
            mimeType: 'text/csv')
      ], fileNameOverrides: [
        name
      ], sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1)));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('CSV export failed: $error')));
    }
  }

  Widget _ledgerPage() {
    final all = ledger.records.values.toList().reversed.toList();
    final filtered = all
        .where((r) =>
            (historySymbol == 'All' || r.symbol == historySymbol) &&
            (historyMode == 'All' || r.condition == historyMode) &&
            (historyOutcome == 'All' || r.observation == historyOutcome) &&
            (historyPaper == 'All' || r.paper == historyPaper))
        .toList();
    final conditions = [
      'All',
      ...{...all.map((r) => r.condition), modeLabel}
    ];
    final pages = max(1, (filtered.length / 30).ceil());
    final page = min(historyPage, pages - 1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Signal Ledger',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
      Text(
          '${all.length} signals retained • ${filtered.length} match filters. Every issued signal remains, including missed, expired and skipped paper entries.'),
      const Text(
          'Stored on this device. Export backups before clearing app data or uninstalling.',
          style: TextStyle(color: Colors.amber)),
      const SizedBox(height: 8),
      FilledButton.icon(
          onPressed: ledgerReady ? _exportLedger : null,
          icon: const Icon(Icons.ios_share),
          label: const Text('EXPORT ALL CSV')),
      Wrap(spacing: 12, runSpacing: 12, children: [
        _filter('Market', historySymbol,
            ['All', ...markets.map((m) => m.symbol)], (v) => historySymbol = v),
        _filter('Condition / barrier', historyMode, conditions,
            (v) => historyMode = v),
        _filter(
            'Forecast outcome',
            historyOutcome,
            [
              'All',
              'pending',
              'correct',
              'incorrect',
              'expired',
              'missed',
              'cancelled'
            ],
            (v) => historyOutcome = v),
        _filter(
            'Paper status',
            historyPaper,
            [
              'All',
              'skipped',
              'waiting',
              'open',
              'won',
              'lost',
              'expired',
              'cancelled',
              'unresolved',
              'assumed_lost'
            ],
            (v) => historyPaper = v),
      ]),
      const SizedBox(height: 16),
      if (filtered.isEmpty)
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No signals match these filters.')),
      ...filtered.skip(page * 30).take(30).map(_signalCard),
      Row(children: [
        TextButton(
            onPressed:
                page > 0 ? () => _refresh(() => historyPage = page - 1) : null,
            child: const Text('PREVIOUS')),
        Text('Page ${page + 1} / $pages'),
        TextButton(
            onPressed: page + 1 < pages
                ? () => _refresh(() => historyPage = page + 1)
                : null,
            child: const Text('NEXT'))
      ]),
      _performanceTable(),
    ]);
  }
}
