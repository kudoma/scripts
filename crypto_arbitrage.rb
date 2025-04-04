require 'net/http'
require 'json'
require 'uri'
require 'time'
require 'fileutils'

# 取引所APIのエンドポイント
COINCHECK_ORDERBOOK_API = "https://coincheck.com/api/order_books"
BITFLYER_ORDERBOOK_API = "https://api.bitflyer.com/v1/board"
BITBANK_ORDERBOOK_API = "https://public.bitbank.cc/%s_%s/depth"

# 3つの取引所に共通して上場している通貨ペア（2024年現在）
COMMON_PAIRS = [
  { symbol: "btc", coincheck: "btc_jpy", bitflyer: "BTC_JPY", bitbank: "btc_jpy" },
  { symbol: "eth", coincheck: "eth_jpy", bitflyer: "ETH_JPY", bitbank: "eth_jpy" },
  { symbol: "xrp", coincheck: "xrp_jpy", bitflyer: "XRP_JPY", bitbank: "xrp_jpy" }
]

# 手数料率（%）- 実際の数値に調整してください
COINCHECK_MAKER_FEE = 0.0  # Coincheckのメイカー手数料
COINCHECK_TAKER_FEE = 0.1  # Coincheckのテイカー手数料
BITFLYER_MAKER_FEE = 0.0   # bitFlyerのメイカー手数料
BITFLYER_TAKER_FEE = 0.1   # bitFlyerのテイカー手数料
BITBANK_MAKER_FEE = 0.0    # bitbankのメイカー手数料
BITBANK_TAKER_FEE = 0.1    # bitbankのテイカー手数料
TRANSFER_FEE = 0.1         # 送金手数料の概算

# ログ関連の設定
LOG_DIR = "logs"
LOG_INTERVAL = 60 # 60秒（1分）ごとにログを出力

# 裁定取引機会のログを保存する配列
arbitrage_opportunities = []

# 前回のログ出力時間
last_log_time = Time.now

# logsディレクトリが存在しなければ作成
FileUtils.mkdir_p(LOG_DIR) unless Dir.exist?(LOG_DIR)

# 画面をクリアする関数
def clear_screen
  system('clear') || system('cls')
end

# Coincheckの板情報を取得
def get_coincheck_orderbook(pair)
  uri = URI.parse("#{COINCHECK_ORDERBOOK_API}?pair=#{pair}")
  response = Net::HTTP.get_response(uri)
  
  if response.code == "200"
    return JSON.parse(response.body)
  else
    puts "Coincheckの板情報取得に失敗しました: #{response.code} #{response.message}"
    return nil
  end
end

# bitFlyerの板情報を取得
def get_bitflyer_orderbook(pair)
  uri = URI.parse("#{BITFLYER_ORDERBOOK_API}?product_code=#{pair}")
  response = Net::HTTP.get_response(uri)
  
  if response.code == "200"
    return JSON.parse(response.body)
  else
    puts "bitFlyerの板情報取得に失敗しました: #{response.code} #{response.message}"
    return nil
  end
end

# bitbankの板情報を取得
def get_bitbank_orderbook(pair)
  base, quote = pair.split('_')
  uri = URI.parse(BITBANK_ORDERBOOK_API % [base, quote])
  response = Net::HTTP.get_response(uri)
  
  if response.code == "200"
    result = JSON.parse(response.body)
    if result["success"] == 1
      return result["data"]
    end
  end
  
  puts "bitbankの板情報取得に失敗しました: #{response.code} #{response.message}"
  return nil
end

# 裁定取引の機会を分析
def analyze_arbitrage(pair)
  # 各取引所の板情報を取得
  coincheck_orderbook = get_coincheck_orderbook(pair[:coincheck])
  bitflyer_orderbook = get_bitflyer_orderbook(pair[:bitflyer])
  bitbank_orderbook = get_bitbank_orderbook(pair[:bitbank])
  
  return nil if coincheck_orderbook.nil? || bitflyer_orderbook.nil? || bitbank_orderbook.nil?
  
  begin
    # 各取引所の最良気配値を取得
    coincheck_best_bid = coincheck_orderbook["bids"][0][0].to_f
    coincheck_best_ask = coincheck_orderbook["asks"][0][0].to_f
    
    bitflyer_best_bid = bitflyer_orderbook["bids"][0]["price"].to_f
    bitflyer_best_ask = bitflyer_orderbook["asks"][0]["price"].to_f
    
    bitbank_best_bid = bitbank_orderbook["bids"][0][0].to_f
    bitbank_best_ask = bitbank_orderbook["asks"][0][0].to_f
    
    # 各取引所間の裁定取引の収益率を計算
    # 1. Coincheck -> bitFlyer
    cc_bf_profit_rate = calculate_profit_rate(
      buy_price: coincheck_best_ask, buy_fee: COINCHECK_TAKER_FEE,
      sell_price: bitflyer_best_bid, sell_fee: BITFLYER_MAKER_FEE
    )
    
    # 2. bitFlyer -> Coincheck
    bf_cc_profit_rate = calculate_profit_rate(
      buy_price: bitflyer_best_ask, buy_fee: BITFLYER_TAKER_FEE,
      sell_price: coincheck_best_bid, sell_fee: COINCHECK_MAKER_FEE
    )
    
    # 3. Coincheck -> bitbank
    cc_bb_profit_rate = calculate_profit_rate(
      buy_price: coincheck_best_ask, buy_fee: COINCHECK_TAKER_FEE,
      sell_price: bitbank_best_bid, sell_fee: BITBANK_MAKER_FEE
    )
    
    # 4. bitbank -> Coincheck
    bb_cc_profit_rate = calculate_profit_rate(
      buy_price: bitbank_best_ask, buy_fee: BITBANK_TAKER_FEE,
      sell_price: coincheck_best_bid, sell_fee: COINCHECK_MAKER_FEE
    )
    
    # 5. bitFlyer -> bitbank
    bf_bb_profit_rate = calculate_profit_rate(
      buy_price: bitflyer_best_ask, buy_fee: BITFLYER_TAKER_FEE,
      sell_price: bitbank_best_bid, sell_fee: BITBANK_MAKER_FEE
    )
    
    # 6. bitbank -> bitFlyer
    bb_bf_profit_rate = calculate_profit_rate(
      buy_price: bitbank_best_ask, buy_fee: BITBANK_TAKER_FEE,
      sell_price: bitflyer_best_bid, sell_fee: BITFLYER_MAKER_FEE
    )
    
    # 結果をまとめる
    result = {
      timestamp: Time.now,
      symbol: pair[:symbol].upcase,
      coincheck_best_bid: coincheck_best_bid,
      coincheck_best_ask: coincheck_best_ask,
      bitflyer_best_bid: bitflyer_best_bid,
      bitflyer_best_ask: bitflyer_best_ask,
      bitbank_best_bid: bitbank_best_bid,
      bitbank_best_ask: bitbank_best_ask,
      cc_bf_profit_rate: cc_bf_profit_rate,
      bf_cc_profit_rate: bf_cc_profit_rate,
      cc_bb_profit_rate: cc_bb_profit_rate,
      bb_cc_profit_rate: bb_cc_profit_rate,
      bf_bb_profit_rate: bf_bb_profit_rate,
      bb_bf_profit_rate: bb_bf_profit_rate
    }
    
    return result
  rescue => e
    puts "データ解析中にエラーが発生しました: #{e.message}"
    return nil
  end
end

# 収益率計算
def calculate_profit_rate(buy_price:, buy_fee:, sell_price:, sell_fee:)
  # 買値に手数料を上乗せ
  actual_buy_price = buy_price * (1 + buy_fee / 100)
  # 売値から手数料と送金手数料を差し引く
  actual_sell_price = sell_price * (1 - sell_fee / 100 - TRANSFER_FEE / 100)
  # 収益率を計算
  profit = actual_sell_price - actual_buy_price
  profit_rate = (profit / buy_price * 100).round(3)
  
  return profit_rate
end

# 裁定取引機会があるか確認
def check_arbitrage_opportunities(result)
  opportunities = []
  
  routes = [
    { from: "Coincheck", to: "bitFlyer", rate: result[:cc_bf_profit_rate] },
    { from: "bitFlyer", to: "Coincheck", rate: result[:bf_cc_profit_rate] },
    { from: "Coincheck", to: "bitbank", rate: result[:cc_bb_profit_rate] },
    { from: "bitbank", to: "Coincheck", rate: result[:bb_cc_profit_rate] },
    { from: "bitFlyer", to: "bitbank", rate: result[:bf_bb_profit_rate] },
    { from: "bitbank", to: "bitFlyer", rate: result[:bb_bf_profit_rate] }
  ]
  
  routes.each do |route|
    if route[:rate] > 0
      opportunities << {
        timestamp: result[:timestamp],
        symbol: result[:symbol],
        from: route[:from],
        to: route[:to],
        profit_rate: route[:rate],
        coincheck_bid: result[:coincheck_best_bid],
        coincheck_ask: result[:coincheck_best_ask],
        bitflyer_bid: result[:bitflyer_best_bid],
        bitflyer_ask: result[:bitflyer_best_ask],
        bitbank_bid: result[:bitbank_best_bid],
        bitbank_ask: result[:bitbank_best_ask]
      }
    end
  end
  
  return opportunities
end

# ログファイルに書き出す
def write_log_file(opportunities)
  return if opportunities.empty?
  
  timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
  log_file = File.join(LOG_DIR, "arbitrage_#{timestamp}.csv")
  
  # CSVファイルに書き出し
  File.open(log_file, "w") do |file|
    # ヘッダー行
    file.puts "時刻,通貨,購入取引所,売却取引所,収益率(%),Coincheck買値,Coincheck売値,bitFlyer買値,bitFlyer売値,bitbank買値,bitbank売値"
    
    # データ行
    opportunities.each do |op|
      time_str = op[:timestamp].strftime("%Y-%m-%d %H:%M:%S")
      file.puts "#{time_str},#{op[:symbol]},#{op[:from]},#{op[:to]},#{op[:profit_rate]},#{op[:coincheck_bid]},#{op[:coincheck_ask]},#{op[:bitflyer_bid]},#{op[:bitflyer_ask]},#{op[:bitbank_bid]},#{op[:bitbank_ask]}"
    end
  end
  
  puts "ログファイルを出力しました: #{log_file}"
end

# 結果を表示する関数
def display_results(arbitrage_results, last_update, opportunities_count)
  # 最も収益率の高い順にソート
  sorted_results = arbitrage_results.sort_by do |r|
    [
      r[:cc_bf_profit_rate], r[:bf_cc_profit_rate],
      r[:cc_bb_profit_rate], r[:bb_cc_profit_rate],
      r[:bf_bb_profit_rate], r[:bb_bf_profit_rate]
    ].max
  end.reverse
  
  clear_screen
  
  puts "============== 裁定取引監視ツール =============="
  puts "最終更新: #{last_update.strftime('%Y-%m-%d %H:%M:%S')}"
  puts "検出された裁定機会: #{opportunities_count}件"
  puts "\n============== 取引所間の最良気配値比較 =============="
  puts "銘柄  | Coincheck買/売 | bitFlyer買/売 | bitbank買/売"
  puts "========================================================================="
  
  sorted_results.each do |r|
    puts sprintf("%-5s | %-7.1f/%-7.1f | %-7.1f/%-7.1f | %-7.1f/%-7.1f",
      r[:symbol],
      r[:coincheck_best_bid], r[:coincheck_best_ask],
      r[:bitflyer_best_bid], r[:bitflyer_best_ask],
      r[:bitbank_best_bid], r[:bitbank_best_ask]
    )
  end
  
  puts "\n============== 収益性のある裁定取引機会 =============="
  puts "※ プラスの値は利益が出る可能性があることを示します"
  puts
  
  # 通貨ごとに裁定機会を表示
  sorted_results.each do |result|
    symbol = result[:symbol]
    puts "#{symbol}:"
    
    profitable_routes = []
    
    # 各取引経路の収益率を表示（収益性のある取引は強調表示）
    routes = [
      { name: "Coincheck → bitFlyer", rate: result[:cc_bf_profit_rate] },
      { name: "bitFlyer → Coincheck", rate: result[:bf_cc_profit_rate] },
      { name: "Coincheck → bitbank", rate: result[:cc_bb_profit_rate] },
      { name: "bitbank → Coincheck", rate: result[:bb_cc_profit_rate] },
      { name: "bitFlyer → bitbank", rate: result[:bf_bb_profit_rate] },
      { name: "bitbank → bitFlyer", rate: result[:bb_bf_profit_rate] }
    ]
    
    routes.each do |route|
      if route[:rate] > 0
        puts "  \e[32m#{route[:name]}: +#{route[:rate]}%\e[0m" # 緑色で表示
        profitable_routes << "#{route[:name]} (#{route[:rate]}%)"
      else
        puts "  #{route[:name]}: #{route[:rate]}%"
      end
    end
    
    puts "\n  収益性のある取引経路:"
    if profitable_routes.any?
      profitable_routes.sort_by { |route| -route.scan(/\((.+?)%\)/).flatten.first.to_f }.each do |route|
        puts "  - \e[32m#{route}\e[0m" # 緑色で表示
      end
    else
      puts "  現在、手数料を考慮すると利益の見込める裁定取引の機会はありません。"
    end
    puts
  end
  
  puts "Ctrl+Cで終了 | ログは#{LOG_INTERVAL}秒ごとに#{LOG_DIR}フォルダに保存されます"
end

# メインループ
begin
  puts "裁定取引監視を開始します。1秒ごとに更新し、裁定機会があれば記録します。"
  puts "ログは#{LOG_INTERVAL}秒ごとに#{LOG_DIR}フォルダに保存されます。"
  puts "Ctrl+Cで終了できます。"
  sleep 2
  
  loop do
    begin
      current_time = Time.now
      arbitrage_results = []
      new_opportunities = []
      
      COMMON_PAIRS.each do |pair|
        result = analyze_arbitrage(pair)
        if result
          arbitrage_results << result
          
          # 裁定取引機会を確認して記録
          opportunities = check_arbitrage_opportunities(result)
          if opportunities.any?
            new_opportunities.concat(opportunities)
            arbitrage_opportunities.concat(opportunities)
          end
        end
      end
      
      # 1分ごとにログファイルを出力
      if (current_time - last_log_time) >= LOG_INTERVAL && arbitrage_opportunities.any?
        write_log_file(arbitrage_opportunities)
        arbitrage_opportunities.clear
        last_log_time = current_time
      end
      
      display_results(arbitrage_results, current_time, arbitrage_opportunities.size)
      
      sleep 1 # 1秒待機
    rescue => e
      puts "エラーが発生しました: #{e.message}"
      puts e.backtrace.join("\n")
      sleep 5 # エラー発生時は少し長めに待機
    end
  end
rescue Interrupt
  # 終了前に残っているログをファイルに書き出す
  write_log_file(arbitrage_opportunities) if arbitrage_opportunities.any?
  puts "\n監視を終了します。"
end