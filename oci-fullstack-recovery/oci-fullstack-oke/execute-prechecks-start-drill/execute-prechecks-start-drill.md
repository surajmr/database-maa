# Lab 3: Execute Prechecks and the Full Stack DR Start Drill Plan

## Introduction

In this lab, run prechecks and execute the Full Stack DR **Start Drill** plan from Lab 2. The drill starts recovery in the Phoenix standby region. It does not promote Phoenix to the production role. Leave the drill running after it completes. Lab 4 validates the application there.

Complete Lab 3 Task 1 and start the Start Drill execution in Task 2. Then run Lab 5 in parallel while the Start Drill runs. The Start Drill can take 15–20 minutes. Complete Lab 3 before starting Lab 4.

**Before you begin:** Complete Lab 2 and open the Phoenix OCI Console tab.

Complete Lab 2 first. Use the Phoenix OCI Console tab and the standby DR protection group. Run the plan prechecks and execution from that protection group.

The application namespace is `ai-fsdr-lab`. The Start Drill restores the application resources for this namespace in the Phoenix standby OKE cluster.

Estimated Time: 20 minutes

### Objectives

In this lab, you will:

- Run prechecks for the Full Stack DR Start Drill plan.
- Review the precheck results and address any blocking failures.
- Start the drill and monitor the plan execution.

## Task 1: Run Start Drill Plan Prechecks

1. In the Phoenix OCI Console, select your assigned compartment. Open the navigation menu. Select **Migration & Recovery**, then **Recovery**, and then **Disaster Recovery**.

2. Select **DR Protection groups**, open **fsdr-rag-standby-xxxxx**, and navigate to the **Plans** tab. The `xxxxx` suffix is unique to your environment.

3. Select **fsdr-rag-xxxxx-start-drill**. Confirm the **Start Drill** type and the standby DR protection group.

4. Click **Actions**, select **Run prechecks**, and confirm the action if the Console prompts you. Wait for the precheck execution to finish.

    ![Actions menu with Run prechecks selected for the Start Drill plan](./images/run-start-drill-prechecks.png)

    In the **Run prechecks** dialog, verify the DR plan and **Start drill** type. Leave **Precheck name** blank or enter a name. Keep **Ignore warnings** turned off. Click **Run prechecks**.

    ![Run prechecks dialog for the Start Drill plan](./images/run-prechecks-dialog.png)

5. Open the precheck execution details. Confirm that every precheck succeeds before you start the plan. Expand an entry to view its message, status, and log details.

    The execution page opens on **Plan execution groups**. Review the precheck group and tasks, including the Autonomous Database snapshot conversion, OKE restore, and volume group restore checks. Wait for all blocking checks to succeed.

    ![Start Drill precheck execution groups and task statuses](./images/start-drill-execution-groups.png)

    To view the progress of a plan step, open its **More actions (...)** menu and select **View log**. You can also select **Download log**.

    ![More actions menu with View log for a Start Drill precheck task](./images/start-drill-task-log-menu.png)

    When the precheck execution finishes, confirm that its status is **Succeeded**. Use this result as the gate for starting the Start Drill plan.

    ![Start Drill precheck execution succeeded](./images/start-drill-prechecks-succeeded.png)

    If a precheck fails, use its message and logs to correct the issue. Typical checks cover member availability, protection-group association, replication, permissions, and resource configuration. Run the prechecks again after resolving the issue. Do not start the plan while a blocking precheck fails.

## Task 2: Execute and Monitor the Start Drill Plan

1. Return to the **fsdr-rag-xxxxx-start-drill** plan. Open **Actions** and select **Execute plan**.

    ![Actions menu with Execute plan selected for the Start Drill plan](./images/start-drill-actions-execute-plan.png)

2. In the **Execute plan** dialog, verify the DR plan and **Start drill** type. Leave **Plan execution name** blank. Keep **Enable prechecks** and **Ignore warnings** turned off. Click **Execute plan**.

    ![Execute plan dialog with prechecks and warnings disabled](./images/start-drill-execute-dialog.png)

3. Review the warning dialog. Confirm that you understand the risks and click **Execute plan** to start the drill.

    ![Execute plan warning confirmation](./images/start-drill-execute-warning.png)

    The Start Drill plan runs the drill-specific database, application, OKE, and storage tasks for this protection group. It does not perform a production switchover. It does not promote the Phoenix standby environment to the production role.

4. Open the plan execution created by the Start Drill operation. Select **Plan execution groups** and monitor the execution as it runs. The execution page shows plan groups and their tasks in run order.

    ![Start Drill plan execution in progress](./images/start-drill-execution-in-progress.png)

    Expand each plan execution group to review its child tasks. Full Stack DR runs the volume group restore, Autonomous Database snapshot standby conversion, and OKE standby restore tasks in sequence. A completed group shows **Succeeded**; queued or in-progress groups continue to update.

    ![Start Drill plan execution group task progress](./images/start-drill-execution-task-progress.png)

    **While it runs, you must begin Lab 5: Configure and Execute Full Stack Backup Recovery in a separate tab. Do not start Lab 4 until the Start Drill completes successfully.**

5. Continue expanding plan groups as they run. Monitor each task state and review any warning, failure, or skipped task before you retry or change configuration.

6. Wait until the plan execution status changes to **Succeeded**. Verify that the Start Drill plan has three successful plan groups, with no pending, warning, failed, or skipped steps.

    Open **Plan execution groups** and confirm that the volume group restore, Autonomous Database snapshot standby conversion, and OKE standby restore groups and child tasks all show **Succeeded**.

    ![Start Drill execution groups showing all tasks succeeded](./images/start-drill-execution-groups-succeeded.png)

    After you confirm the successful groups, open the **Details** tab and review the overall execution duration.

    ![Start Drill execution details showing a successful execution and duration](./images/start-drill-execution-succeeded-details.png)

    This execution took approximately 17 minutes. Treat this as an observation, not a guarantee. Execution time varies with service state and workload. Full Stack DR coordinates the underlying service APIs but does not directly control the Recovery Time Objective (RTO). For the Recovery Point Objective (RPO), consult the guidance for each service. Replication lag, snapshot timing, and backup policies determine data currency.

7. Return to the standby DR protection group and confirm that its header shows **Inactive (Drill in progress)** and **Role: Standby**. On the **Plans** tab, confirm that the Start Drill, Failover, and Switchover plans show **Inactive** while the drill remains active.

    ![Standby DR protection group showing drill in progress and inactive plans](./images/standby-drill-in-progress.png)

8. After a Start Drill completes, you can create and run a **Stop Drill** plan to convert the application stack back to its state before the drill. Creating or running a Stop Drill plan is outside the scope of this workshop; leave the drill active for Lab 4.

    A successful **Switchover** or **Failover** plan changes the role of the DR protection group. A **Start Drill** does not change that role; it keeps the protection group in its standby role while the drill runs.

    In Lab 4, you will validate the AI application in the Phoenix region while the Start Drill remains active, including its frontend, backend, database connection, and RAG response.

    You may now [proceed to the next lab](#next).

## Acknowledgements

* **Author** - Suraj Ramesh, Lead Principal Product Manager, Oracle Database High Availability (HA), Scalability and Maximum Availability Architecture (MAA)
* **Last Updated By/Date** - August 2026
