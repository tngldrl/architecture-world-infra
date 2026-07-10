# Micro Grand Maison Infra - Infrastructure as Code (Terraform)

Micro Grand Maison (MGM) のインフラリソース（Google Cloud Platform）をコード管理およびデプロイするための Terraform リポジトリ。

## 🌟 Google Cloud 構成図・対象サービス

システムは、GCP のフルマネージドサービスを用いてセキュアかつ高スケーラブルに構成されています。

```
                       [ GitHub Repositories ]
                                 │
                                 ▼ (git push / Webhook)
[ Users ] ──(HTTPS)──> [ Cloud Run: Web Front ]
                                 │
                             (REST API)
                                 ▼
                       [ Cloud Run: API Core ]
                                 │
                             (REST API)
                                 ▼
                       [ Cloud Run: MCP AI ] ──> [ Vertex AI / Imagen 3 ]
                                 │
                    (Upload generated avatars)
                                 ▼
                       [ Cloud Storage Bucket ]
```

* **Cloud Run (サーバーレスコンテナデプロイ)**:
  * フロントエンド (`web`)、コアバックエンド (`api`)、AI バックエンド (`mcp`) の 3 つのサービスがデプロイされ、トラフィックに応じて自動スケールします。
* **Cloud Storage (GCS) (静的アセットホスト)**:
  * アバター画像を格納・公開する公開アクセス可能なバケット（`[gcp_project_id]-avatars`）をプロビジョニングします。
* **IAM & Service Accounts (認証とセキュリティ)**:
  * `mcp` サービス用に、Vertex AI / AI Platform の利用権限（`roles/aiplatform.user`）および GCS バケットへの書き込み権限（`roles/storage.objectCreator`）を持つ専用の IAM サービスアカウントを定義します。
  * `api` サービス用に、GCS バケットへの読み取り権限（`roles/storage.objectViewer`）を割り当てます。

---

## 📂 主要ディレクトリ・コード構造

```
micro-grand-maison-infra/
├── main.tf            # メインインフラ定義（プロバイダ構成、ローカル変数定義）
├── variables.tf       # デプロイパラメータ入力変数（GCPプロジェクトID、リージョン名など）
├── run.tf             # Cloud Run サービス（web, api, mcp）のリソース定義とIAMバインド設定
├── storage.tf         # アバター配信用 Cloud Storage バケットおよびパブリックIAM読み取りポリシーの定義
├── outputs.tf         # プロビジョニング完了後に出力されるデプロイ先URL等の定義
└── terraform.tfvars   # 実環境向けの設定変数ファイル（git除外対象）
```

---
