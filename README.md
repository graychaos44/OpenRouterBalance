# OpenRouter Balance Monitor

macOS 메뉴 바 앱 — OpenRouter 잔액/사용량 실시간 표시

## 스크린샷

메뉴 바에 잔액이 실시간으로 표시되고, 클릭하면 상세 팝오버가 나타납니다.

## 기능

- 💳 메뉴 바에 잔액 실시간 표시: `💳$9.99 | $5.00`
- 🖱️ 왼쪽 클릭: 상세 팝오버 (Account, Weekly Limit, Usage, Daily Requests)
- 🖱️ 오른쪽 클릭: 컨텍스트 메뉴 (Refresh Now / Quit)
- 🔄 5분 자동 리프레시
- 🔑 API 키 입력으로 다른 계정 사용 가능

## 빌드

```bash
cd ~/scripts/OpenRouterBalance
swiftc -parse-as-library -o OpenRouterBalance.app/Contents/MacOS/OpenRouterBalance App.swift -framework SwiftUI -framework AppKit -framework Combine
```

## 실행

```bash
open ~/scripts/OpenRouterBalance/OpenRouterBalance.app
```

## 구조

```
OpenRouterBalance/
├── App.swift                      # macOS SwiftUI 메뉴 바 앱 소스
├── OpenRouterBalance.app/          # macOS 앱 번들
│   └── Contents/MacOS/OpenRouterBalance
└── README.md
```

## API 키 변경

`App.swift` 상단 `BalanceVM` 클래스에서:

```swift
private let apiKey = "sk-or-v1-xxxxx"  // 여기에 본인 API 키 입력
```

수정 후 재빌드:

```bash
swiftc -parse-as-library -o OpenRouterBalance.app/Contents/MacOS/OpenRouterBalance App.swift -framework SwiftUI -framework AppKit -framework Combine
```

## 팝오버 정보

| 항목 | 설명 |
|------|------|
| Account | $10 크레딧 기준 남은 잔액 |
| Weekly Limit | 주간 사용 한도 (기본 $5/주) |
| Usage | 일/주/월 사용량 |
| Daily Requests | 무료 모델 1000요청/일 |

## 기술 정보

- **언어**: Swift (SwiftUI + AppKit)
- **API**: OpenRouter `/api/v1/auth/key`
- **파싱**: JSONSerialization (API 필드 추가 시에도 안전)
- **자동 새로고침**: 300초 (5분)
- **최소 버전**: macOS 13+ (Ventura)

## 라이선스

MIT